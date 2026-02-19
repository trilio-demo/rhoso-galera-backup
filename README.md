# Galera Backup Solution for RHOSO 18

Complete TrilioVault-based backup and disaster recovery solution for a 3-node
MariaDB Galera cluster in a Red Hat OpenStack Services on OpenShift 18 environment.

**Validated:** All files tested against a live RHOSO 18 cluster (February 2026)
**TVK Version:** 5.2.0
**Target types supported:** NFS, S3-compatible object storage

---

## Files at a Glance

| File | Purpose | Use |
|------|---------|-----|
| `galera-backup-hook.yaml` | TrilioVault Hook CR | Deploy to enable consistent backups |
| `galera-backup-plan.yaml` | TrilioVault BackupPlan CR | Deploy to configure backup schedule and targets |
| `galera-health-check.sh` | Read-only cluster health check | Run anytime to verify cluster + OpenStack health |
| `galera-real-disaster-tests.md` | Disaster recovery test guide | Full procedures, observed results, production caveats |
| `galera-backup-runbook.md` | Operational runbook | Day-to-day operations reference |
| `galera-backup-quick-reference.md` | Quick reference card | On-call cheat sheet |
| `why-this-way.md` | Design rationale | Explains the *why* behind every decision |

---

## Deploy the Backup Solution

### Prerequisites

```bash
# TrilioVault must be installed and a Target CR must exist
oc get pods -n trilio-system
oc get target -n openstack

# Galera cluster must be healthy (3/3, all Synced)
for i in 0 1 2; do
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
     -e "SHOW STATUS LIKE \"wsrep_cluster_size\"; SHOW STATUS LIKE \"wsrep_local_state_comment\";"'
done
```

### Step 1 — Deploy the Hook

```bash
oc apply -f galera-backup-hook.yaml
oc get hook galera-backup-hook -n openstack
```

### Step 2 — Deploy the BackupPlan

Update the target name before applying:

```yaml
# In galera-backup-plan.yaml — update this field to match your Target CR name:
backupConfig:
  target:
    name: sa-lab-nfs-share1   # <-- replace with YOUR target name
    namespace: openstack
```

```bash
oc apply -f galera-backup-plan.yaml
oc get backupplan openstack-galera-backup -n openstack
oc get policy -n openstack
```

### Step 3 — Run a Manual Backup to Verify

```bash
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Backup
metadata:
  name: galera-test-$(date +%Y%m%d-%H%M%S)
  namespace: openstack
spec:
  type: Full
  backupPlan:
    name: openstack-galera-backup
    namespace: openstack
EOF

# Monitor progress
oc get backup -n openstack -w
```

### Step 4 — Verify Cluster Health After Backup

```bash
./galera-health-check.sh
```

All 44 checks should pass. If any fail, consult `galera-backup-runbook.md`.

---

## What Gets Backed Up

The BackupPlan backs up exactly these resources from the `openstack` namespace:

| Resource | Name | Notes |
|----------|------|-------|
| StatefulSet | `openstack-galera` | Cluster definition |
| PVC | `mysql-db-openstack-galera-0` | Data volume (galera-0 only) |
| Secret | `osp-secret` | DB credentials |
| Secret | `combined-ca-bundle` | TLS certificates |
| Service | `openstack-galera` | Cluster endpoint |
| ServiceAccount | `galera-openstack` | RBAC identity |
| ConfigMap | `openstack-config-data` | Cluster configuration |

**galera-1 and galera-2 PVCs are intentionally excluded** — they contain identical
data to galera-0. This saves ~66% backup storage and time. On restore, galera-1
and galera-2 receive their data via Galera SST from galera-0.

---

## How the Hook Works

The Hook runs on `openstack-galera-0` and ensures data consistency:

**Pre-backup:**
1. Verifies all 3 nodes are in `Synced` state
2. Desynchronises galera-0 from the cluster (it stops receiving writes)
3. Verifies desync took effect
4. Locks all tables with `FLUSH TABLES WITH READ LOCK`
5. TrilioVault takes the PVC snapshot

**Post-backup:**
1. Releases the table lock
2. Re-synchronises galera-0 back into the cluster
3. Verifies resync completed

The backup window (lock duration) is approximately 15 seconds. The cluster
continues serving writes through galera-1 and galera-2 during this time.

---

## Disaster Recovery

See **`galera-real-disaster-tests.md`** for complete procedures covering:

- **Test 1:** Single PVC deletion — self-healing, no restore needed
- **Test 2:** Two PVCs deleted — self-healing via SST
- **Test 3:** Restore to separate test namespace (non-destructive validation)
- **Test 4:** Data corruption / all PVCs destroyed — full restore from backup
- **Test 5:** Physical PVC loss — same procedure as Test 4

The document includes real observed outputs from a live cluster, known
considerations for RHOSO 18 (OSCP operator behaviour, `safe_to_bootstrap`
handling), and a comprehensive **Production Restore Caveats** section covering
state divergence across Nova, Cinder, Neutron, Keystone, Barbican, Placement,
Glance, and Heat — with audit commands for each.

### Quick restore reference

```bash
# Scale Galera to 0 (use replicas:0, NOT enabled:false — OSCP blocks it)
oc patch openstackcontrolplane openstack-controlplane -n openstack \
  --type=merge -p '{"spec":{"galera":{"templates":{"openstack":{"replicas":0}}}}}'

# Delete corrupted PVCs
oc delete pvc mysql-db-openstack-galera-{0,1,2} -n openstack

# Apply restore CR (skipIfAlreadyExists skips the existing StatefulSet)
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Restore
metadata:
  name: galera-restore
  namespace: openstack
spec:
  restoreFlags:
    skipIfAlreadyExists: true
  source:
    type: Backup
    backup:
      name: <your-backup-name>
      namespace: openstack
  restoreNamespace: openstack
EOF

# Monitor
oc get restore galera-restore -n openstack -w

# Scale back up after restore completes
oc patch openstackcontrolplane openstack-controlplane -n openstack \
  --type=merge -p '{"spec":{"galera":{"templates":{"openstack":{"replicas":3}}}}}'
```

---

## Health Monitoring

Run the health check script at any time — it is read-only and safe in production:

```bash
./galera-health-check.sh
```

**Checks performed (44 total):**
1. Galera cluster health (wsrep status per node)
2. Kubernetes resource presence (7 backed-up resources)
3. Database presence and table counts
4. Write + replication (creates and drops a temporary test DB)
5. Service endpoint connectivity
6. OpenStack pod status
7. OpenStack API health (Keystone, Nova, Neutron, Glance, Cinder, Placement, Barbican)
8. Key table row counts

---

## Key Design Decisions

**Why only galera-0 PVC in the backup?**
All 3 nodes have identical data. Backing up all 3 would triple storage costs
with no benefit. galera-1 and galera-2 resync via SST on restore.

**Why `replicas: 0` instead of `enabled: false` for restore?**
OSCP validation blocks `enabled: false` on Galera because Keystone, Glance,
Cinder, Nova, Neutron, Placement, Horizon, and Barbican all declare hard
dependencies. `replicas: 0` achieves the same effect without triggering
the validation error.

**Why `skipIfAlreadyExists: true` on the Restore CR?**
When restoring to the same namespace, the StatefulSet still exists (at 0
replicas). This flag tells TVK to skip it and focus only on recreating the
deleted PVCs.

**Why `useOCPNamespaceUIDRange: true` for cross-namespace restores?**
OpenShift assigns a different UID range to each namespace. Restored PVCs
from a different namespace will have wrong file ownership without this flag,
causing MySQL to fail to read its data directory.

---

## Support Resources

- **TrilioVault docs:** https://docs.trilio.io
- **RHOSO 18 docs:** https://docs.redhat.com/en/documentation/red_hat_openstack_services_on_openshift/18.0
- **Galera docs:** https://galeracluster.com/library/documentation/

---

## Document Metadata

**Version:** 2.0
**Created:** February 17, 2026
**Updated:** February 18, 2026
**Environment:** RHOSO 18 / OpenShift / TrilioVault 5.2.0
**Status:** Production-ready — validated against live cluster
