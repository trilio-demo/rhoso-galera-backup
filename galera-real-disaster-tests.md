# Real Galera Disaster Recovery Tests

## Scope

This document covers disaster scenarios for the Galera cluster backed up by Trilio for Kubernetes.

**What the backup includes (from `galera-backup-plan.yaml`):**
- StatefulSet: `openstack-galera`
- PVC: `mysql-db-openstack-galera-0` (only galera-0)
- Secrets: `osp-secret`, `combined-ca-bundle`
- Service: `openstack-galera`
- ServiceAccount: `galera-openstack`
- ConfigMap: `openstack-config-data`

**What the backup does NOT include:**
- PVCs for galera-1 and galera-2 (excluded explicitly)
- Other OpenStack services (Nova, Neutron, Keystone deployments, etc.)
- Other namespace resources not listed above

**Databases in the Galera cluster:**
- **keystone** - Identity (users, projects, roles, endpoints)
- **nova_api** - Compute API (instance mappings, flavors, quotas)
- **nova_cell0** - Compute Cell0 (failed-to-schedule instances)
- **neutron** - Networking (networks, subnets, ports, routers, security groups)
- **glance** - Image service (image metadata)
- **cinder** - Block storage (volume metadata, snapshots)
- **placement** - Resource providers and allocations
- **barbican** - Key manager (secrets, certificates)
- **dmapi** - Data mover API
- **workloadmgr** - Trilio for OpenStack (cloud-level backup metadata, NOT the T4K product doing this backup)

**Backup used for testing:** `secondtrygalera` (Full, Available, 584MB)
**Target:** `sa-lab-nfs-share1` (NFS) — see note below

> **Target type note:** These tests were performed using an NFS Backup Target.
> Trilio for Kubernetes also supports S3-compatible object storage targets. The backup,
> restore, and verification procedures are identical regardless of target type.
> Where this document refers to "Backup Target (NFS/S3)", the steps apply to both.
> The restore and verification procedures behave identically on both target types.

---

## Self-Healing Tests (No Backup Required)

These tests prove Galera's built-in resilience. Run these FIRST to understand
what Galera handles on its own before testing backup restore.

### Test 1: Single PVC Deletion

**Disaster:** One PVC deleted (any node, including galera-0)
**Why no backup needed:** Surviving nodes serve as SST donors

```bash
# ============================================================
# PRE-DISASTER: Record baseline
# ============================================================

oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES;"' > /tmp/databases-before-test1.txt

# ============================================================
# EXECUTE DISASTER
# ============================================================

# 1. Scale down Galera
# # NOTE: On RHOSO 18.0.2+ (operator v1.0.3+), replicas: 0 is blocked by CRD webhook.
# Scale down both operators first, then scale the StatefulSet directly.
oc scale deployment mariadb-operator-controller-manager -n openstack-operators --replicas=0
oc scale deployment openstack-operator-controller-manager -n openstack-operators --replicas=0
oc scale statefulset openstack-galera -n openstack --replicas=0

# 2. Wait for pods to terminate
oc wait --for=delete pod/openstack-galera-0 \
  pod/openstack-galera-1 \
  pod/openstack-galera-2 \
  -n openstack --timeout=120s

# 3. Delete galera-0 PVC
oc delete pvc mysql-db-openstack-galera-0 -n openstack

# 4. Verify PVC is gone
oc get pvc -n openstack | grep galera

# ============================================================
# RECOVERY (self-healing via SST)
# ============================================================

# 5. Scale back up - galera-0 gets a fresh empty PVC
#    galera-1 and galera-2 have their data and will form the cluster.
#    galera-0 detects empty datadir and requests SST from a donor.
oc scale statefulset openstack-galera -n openstack --replicas=3
oc scale deployment mariadb-operator-controller-manager -n openstack-operators --replicas=1
oc scale deployment openstack-operator-controller-manager -n openstack-operators --replicas=1

# 6. Wait for pod to initialize, then watch SST progress
#    (pod takes ~10s to start - "PodInitializing" is expected initially)
sleep 15
oc logs -f openstack-galera-0 -n openstack -c galera

# 7. Verify cluster health after SST completes
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
      SHOW STATUS LIKE \"wsrep_cluster_size\";
      SHOW STATUS LIKE \"wsrep_local_state_comment\";
      SHOW VARIABLES LIKE \"wsrep_desync\";"' 2>/dev/null || echo "Not ready yet"
done

# 8. Verify data intact
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES;"' > /tmp/databases-after-test1.txt
diff /tmp/databases-before-test1.txt /tmp/databases-after-test1.txt

# 9. Verify replication works (write on galera-0, read on galera-2)
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "
    CREATE DATABASE sst_verify; USE sst_verify;
    CREATE TABLE t (id INT); INSERT INTO t VALUES (42);"'
oc exec openstack-galera-2 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT * FROM sst_verify.t;"'
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DROP DATABASE sst_verify;"'
```

**Expected Results:**
- galera-0 detects empty datadir and requests SST automatically
- galera-1 or galera-2 serves as donor
- Cluster returns to 3-node "Synced" state
- All databases present (diff shows no differences)
- Replication verified across nodes
- Recovery time: seconds to minutes depending on database size and storage speed

**After completion:** Run the full [Post-Recovery Verification](#post-recovery-verification-run-after-every-test)

---

### Test 2: Two PVCs Deleted

**Disaster:** Two PVCs lost, only 1 surviving node
**Why no backup needed:** 1 survivor is enough for SST

```bash
# ============================================================
# PRE-DISASTER: Record baseline
# ============================================================

oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES;"' > /tmp/databases-before-test2.txt

# ============================================================
# EXECUTE DISASTER
# ============================================================

# 1. Scale down Galera
# NOTE: On RHOSO 18.0.2+ (operator v1.0.3+), replicas: 0 is blocked by CRD webhook.
# Scale down both operators first, then scale the StatefulSet directly.
oc scale deployment mariadb-operator-controller-manager -n openstack-operators --replicas=0
oc scale deployment openstack-operator-controller-manager -n openstack-operators --replicas=0
oc scale statefulset openstack-galera -n openstack --replicas=0
oc wait --for=delete pod/openstack-galera-0 \
  pod/openstack-galera-1 \
  pod/openstack-galera-2 \
  -n openstack --timeout=120s

# 2. Delete galera-0 and galera-1 PVCs
oc delete pvc mysql-db-openstack-galera-0 -n openstack
oc delete pvc mysql-db-openstack-galera-1 -n openstack

# ============================================================
# RECOVERY (self-healing via SST from single survivor)
# ============================================================

# 3. Scale back up
#    galera-2 has data and bootstraps the cluster.
#    galera-0 and galera-1 get empty PVCs and SST from galera-2.
#    NOTE: SST is sequential - only 1 joiner at a time gets served.
oc scale statefulset openstack-galera -n openstack --replicas=3
oc scale deployment mariadb-operator-controller-manager -n openstack-operators --replicas=1
oc scale deployment openstack-operator-controller-manager -n openstack-operators --replicas=1

# 4. Monitor - galera-0 and galera-1 should SST from galera-2
sleep 15
oc logs -f openstack-galera-0 -n openstack -c galera

# 5. Verify all 3 synced (may need to wait and retry)
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
      SHOW STATUS LIKE \"wsrep_cluster_size\";
      SHOW STATUS LIKE \"wsrep_local_state_comment\";"' 2>/dev/null || echo "Not ready yet"
done

# 6. Verify data intact
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES;"' > /tmp/databases-after-test2.txt
diff /tmp/databases-before-test2.txt /tmp/databases-after-test2.txt

# 7. Verify cross-node replication
oc exec openstack-galera-1 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "
    CREATE DATABASE sst_verify2; USE sst_verify2;
    CREATE TABLE t (id INT); INSERT INTO t VALUES (99);"'
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT * FROM sst_verify2.t;"'
oc exec openstack-galera-1 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DROP DATABASE sst_verify2;"'
```

**Expected Results:**
- galera-2 (only survivor) serves as SST donor
- galera-0 and galera-1 rebuild from galera-2
- Cluster returns to 3-node "Synced" state
- All databases present (diff shows no differences)
- Replication verified across all nodes
- Recovery time: varies (2 sequential SST transfers; fast in dev, longer in production with large datasets)

**After completion:** Run the full [Post-Recovery Verification](#post-recovery-verification-run-after-every-test)

---

## Backup Restore Tests (Backup Required)

These are the scenarios where Galera cannot self-heal and your Trilio for Kubernetes
backup is the only recovery path.

### Test 3: Restore to Test Namespace (Non-Destructive Validation)

**Purpose:** Validate backup integrity and restore process without touching production

**Important limitation:** Galera will NOT form a real cluster in the test namespace.
There is no OSCP operator managing it, DNS endpoints are wrong, and there are no
peer members. The pod will likely enter CrashLoopBackOff or hang — this is expected.
Verification focuses on two levels: resource presence and filesystem data integrity.

```bash
# ============================================================
# RESTORE
# ============================================================

# 1. Create test namespace
oc create namespace galera-restore-test

# 2. Create restore
#    IMPORTANT:
#    - Restore CR is created in the TARGET namespace (galera-restore-test)
#    - useOCPNamespaceUIDRange: true remaps file ownership on the restored PVC
#      to match the target namespace's random UID range (critical in OpenShift)
#    - skipIfAlreadyExists: true avoids conflicts on re-runs
cat <<'EOF' | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Restore
metadata:
  name: test-restore-validation
  namespace: galera-restore-test
spec:
  restoreFlags:
    skipIfAlreadyExists: true
    useOCPNamespaceUIDRange: true
  source:
    type: Backup
    backup:
      name: secondtrygalera
      namespace: openstack
  restoreNamespace: galera-restore-test
EOF

# 3. Monitor restore progress
oc get restore test-restore-validation -n galera-restore-test -w
# Wait for status: Completed
# Typical phases and durations (observed):
#   Validation:              ~17 min
#   PrimitiveMetadataRestore: ~26s
#   DataRestore:              ~41s  (410MB)
#   MetadataRestore:          ~1m38s
#   Total:                    ~19 min

# ============================================================
# LEVEL 1: RESOURCE VERIFICATION
# ============================================================

# 4. All 7 backed-up resources must be present
oc get statefulset,pvc,secret,service,serviceaccount,configmap -n galera-restore-test

# 5. PVC must be Bound (Pending = data not restored)
oc get pvc -n galera-restore-test
# Expected: mysql-db-openstack-galera-0   Bound

# 6. Check what the pod is doing (CrashLoopBackOff or Init is expected)
oc get pods -n galera-restore-test
oc describe pod openstack-galera-0 -n galera-restore-test | tail -20

# ============================================================
# LEVEL 2: FILESYSTEM / DATA INTEGRITY VERIFICATION
# (works even if pod is CrashLooping - PVC is still mounted)
# ============================================================

# 7. Datadir must contain all database directories
oc exec openstack-galera-0 -n galera-restore-test -c galera -- \
  ls /var/lib/mysql/ 2>/dev/null
# Expected: barbican/ cinder/ dmapi/ glance/ keystone/ neutron/
#           nova_api/ nova_cell0/ placement/ workloadmgr/ ibdata1 ...

# 8. grastate.dat - MOST IMPORTANT CHECK
#    Proves the backup captured a consistent state
oc exec openstack-galera-0 -n galera-restore-test -c galera -- \
  cat /var/lib/mysql/grastate.dat 2>/dev/null
# Expected healthy output:
#   version: 2.1
#   uuid:    <some-uuid>     ← must not be zeros
#   seqno:   <positive int>  ← -1 means unclean shutdown (problem!)
#   safe_to_bootstrap: 0     ← 0 or 1, both acceptable here
#
# The hook uses FLUSH TABLES WITH READ LOCK + desync to ensure seqno > 0

# 9. ibdata1 must have real size (not 0 bytes)
oc exec openstack-galera-0 -n galera-restore-test -c galera -- \
  du -sh /var/lib/mysql/ibdata1 2>/dev/null
# Expected: ~76M or similar (not 0)

# 10. File counts per database directory - compare against baseline table counts
oc exec openstack-galera-0 -n galera-restore-test -c galera -- bash -c \
  'for db in barbican cinder dmapi glance keystone neutron nova_api nova_cell0 placement workloadmgr; do
     count=$(ls /var/lib/mysql/$db/ 2>/dev/null | wc -l)
     echo "$db: $count files"
   done'
# Each database should have files proportional to its table count
# (roughly 2-3 files per table: .frm, .ibd, etc.)

# 11. Size of key database directories
oc exec openstack-galera-0 -n galera-restore-test -c galera -- \
  du -sh /var/lib/mysql/keystone \
         /var/lib/mysql/neutron \
         /var/lib/mysql/nova_api \
         /var/lib/mysql/nova_cell0 2>/dev/null
# Should show non-trivial sizes matching a real OpenStack deployment

# ============================================================
# LEVEL 3: MYSQL QUERY VERIFICATION (validated debug pod method)
# The restored pods crash-loop in an isolated namespace because
# there is no OSCP operator managing them. Use a debug pod to
# access the data directly from the PVC instead.
# ============================================================

# 12. Delete the crash-looping StatefulSet (keeps PVCs intact)
oc -n galera-restore-test delete sts openstack-galera

# 13. Get the correct MariaDB image from your cluster
GALERA_IMAGE=$(oc get galera openstack -n openstack -o jsonpath='{.spec.containerImage}')
echo "Using image: ${GALERA_IMAGE}"

# 14. Create a debug pod mounting the restored PVC
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: galera-debug-mysql
  namespace: galera-restore-test
spec:
  restartPolicy: Never
  containers:
    - name: mariadb
      image: ${GALERA_IMAGE}
      command: ["/bin/bash", "-c", "sleep infinity"]
      volumeMounts:
        - name: mysql-data
          mountPath: /var/lib
      env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: osp-secret
              key: DbRootPassword
  volumes:
    - name: mysql-data
      persistentVolumeClaim:
        claimName: mysql-db-openstack-galera-0
EOF

# 15. Wait for debug pod to be Running
oc get pod galera-debug-mysql -n galera-restore-test -w

# 16. Exec into the debug pod
oc -n galera-restore-test rsh galera-debug-mysql

# 17. Inside the pod - start MySQL manually and query data
mysqld_safe --datadir=/var/lib/mysql --skip-networking --skip-grant-tables &
# Wait a few seconds for mysqld to start, then:
mysql -u root
# Run your queries:
#   show databases;
#   use keystone; show tables;
#   SELECT * FROM project LIMIT 5;

# ============================================================
# CLEANUP
# ============================================================

# 18. Cleanup
oc delete namespace galera-restore-test
```

**Pass Criteria:**

| Check | Expected |
|-------|----------|
| Restore status | `Completed` |
| PVC status | `Bound` |
| All resources | Present (see note below) |
| Pod status | Running (but not Ready — expected, crash-loop before debug pod) |
| Pod restart reason | `Startup probe failed: waiting for gcomm URI` — expected |
| `grastate.dat` exists | Yes |
| `grastate.dat` seqno | `-1` — expected (see note below) |
| `grastate.dat` uuid | Non-zero UUID |
| `ibdata1` size | ~76M |
| Database directories | All 10 present with files |
| MySQL query via debug pod | Responds after `mysqld_safe --skip-networking --skip-grant-tables` |

**Why seqno is -1 (this is correct and expected):**
Galera writes `-1` to `grastate.dat` while the node is *running* — it's a
"node is live" marker. The real sequence number lives in memory. Only on a
clean shutdown does Galera flush the actual seqno to disk. Because the backup
hook locks tables with `FLUSH TABLES WITH READ LOCK` but does NOT stop MySQL,
the PVC snapshot captures `seqno: -1`. The data is fully consistent — the lock
ensures that. In a real restore (Tests 4, 5, 6), galera-0 starts with this
`-1`. For Tests 4/5/6 the OSCP galera operator handles `safe_to_bootstrap` automatically.
For Test 3 (different namespace, no OSCP operator), manual intervention may be needed.

**Why pods restart with "waiting for gcomm URI":**
Galera's startup probe waits for a valid `gcomm://` cluster URI. In the test
namespace there are no peers and no OSCP operator to configure endpoints, so
the probe never succeeds. The pods keep restarting — this is completely expected
and does not indicate a problem with the backup data.

**Resources actually restored (observed from UI):**
Trilio for Kubernetes restores more than just the 7 resources listed in the BackupPlan —
it also captures cluster-managed resources associated with the workload:
- ServiceAccount: `galera-openstack`
- Secrets: `osp-secret`, `combined-ca-bundle`, `cert-galera-openstack-svc`
- Role: `galera-openstack-role`
- RoleBinding: `galera-openstack-rolebinding`
  *(namespace automatically updated: `openstack` → `galera-restore-test`)*
- ConfigMaps: `openstack-config-data`, `openstack-scripts`
- StatefulSet: `openstack-galera`
- ControllerRevisions (StatefulSet history)
- PVC: `mysql-db-openstack-galera-0` (with data)

**Reference: Observed Output (2026-02-18)**

```
# Pods - Running but not Ready, restarting every ~60s (expected)
NAME                 READY   STATUS    RESTARTS      AGE
openstack-galera-0   0/1     Running   4 (62s ago)   17m
openstack-galera-1   0/1     Running   4 (61s ago)   17m
openstack-galera-2   0/1     Running   4 (68s ago)   17m

# Startup probe failure message (expected):
# Startup probe failed: waiting for gcomm URI

# grastate.dat
# GALERA saved state
version: 2.1
uuid:    3df1abde-6d11-11f0-a44a-be73394a105d
seqno:   -1                  ← expected for live backup
safe_to_bootstrap: 0

# ibdata1
76M     /var/lib/mysql/ibdata1

# File counts per database
barbican: 55 files
cinder: 73 files
dmapi: 5 files
glance: 29 files
keystone: 99 files
neutron: 381 files
nova_api: 65 files
nova_cell0: 221 files
placement: 27 files
workloadmgr: 139 files

# Directory sizes
4.2M    /var/lib/mysql/keystone
29M     /var/lib/mysql/neutron
3.5M    /var/lib/mysql/nova_api
9.9M    /var/lib/mysql/nova_cell0
```

Note: All 3 PVCs were created (`galera-0`, `galera-1`, `galera-2`) — only
`galera-0` has restored data; `galera-1` and `galera-2` were created empty
by the StatefulSet's `volumeClaimTemplates`.

---

**useOCPNamespaceUIDRange:** Without this flag, the pod would fail to read its
own datadir because files on the PVC are owned by the source namespace UID
(e.g. `1000700000`) while the target namespace assigns a different UID range
(e.g. `1000840000`). Trilio for Kubernetes remaps ownership on restore when this flag is set.

**Using the UI instead of CLI:**
When creating the restore in the Trilio for Kubernetes UI, ensure you enable:
- **Skip if already exists** → `skipIfAlreadyExists: true`
- **Use OCP Namespace UID Range** → `useOCPNamespaceUIDRange: true`

**Production namespace:** Completely unaffected. No changes made.
Skip `galera-health-check.sh` for this test (test namespace only).

---

### Test 4: Data Corruption Recovery

**Disaster:** Data corrupted/deleted, replicated to all 3 nodes via Galera
**Why backup needed:** Corruption is replicated everywhere, no clean donor exists

```bash
# ============================================================
# PRE-DISASTER: Record baseline
# ============================================================

# Use a TEST database - do NOT drop real OpenStack tables for testing!
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "
    CREATE DATABASE IF NOT EXISTS backup_test;
    USE backup_test;
    CREATE TABLE IF NOT EXISTS test_data (
      id INT AUTO_INCREMENT PRIMARY KEY,
      value VARCHAR(255),
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    INSERT INTO test_data (value) VALUES
      (\"record1\"), (\"record2\"), (\"record3\"), (\"record4\"), (\"record5\");
    SELECT COUNT(*) AS row_count FROM test_data;"'

# Record all databases
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES;"' > /tmp/databases-before.txt

# ============================================================
# IMPORTANT: Take a NEW backup AFTER creating test data
# (so the backup contains the test database)
# ============================================================

cat <<'EOF' | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Backup
metadata:
  name: pre-corruption-backup
  namespace: openstack
spec:
  type: Full
  backupPlan:
    name: openstack-galera-backup
    namespace: openstack
EOF

# Wait for backup to complete
echo "Waiting for backup..."
while true; do
  STATUS=$(oc get backup pre-corruption-backup -n openstack \
    -o jsonpath='{.status.status}' 2>/dev/null)
  if [ "$STATUS" = "Available" ]; then
    echo "Backup completed!"
    break
  elif [ "$STATUS" = "Failed" ]; then
    echo "Backup FAILED - do not proceed"
    break
  fi
  echo -n "."
  sleep 10
done

# ============================================================
# EXECUTE DISASTER: Simulate corruption
# ============================================================

# Drop the test database (Galera replicates this to ALL nodes)
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DROP DATABASE backup_test;"'

# Verify corruption propagated to all nodes
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES;"' 2>/dev/null | grep backup_test || echo "backup_test MISSING"
done

# ============================================================
# RECOVERY: Restore from pre-corruption backup
# ============================================================

# NOTE: On RHOSO 18.0.2+ (operator v1.0.3+), replicas: 0 is blocked by CRD webhook.
# Both `enabled: false` and `replicas: 0` are rejected. Scale down both operators
# first, then scale the StatefulSet directly.

# 1. Scale down Galera
oc scale deployment mariadb-operator-controller-manager -n openstack-operators --replicas=0
oc scale deployment openstack-operator-controller-manager -n openstack-operators --replicas=0
oc scale statefulset openstack-galera -n openstack --replicas=0

oc wait --for=delete pod/openstack-galera-0 \
  pod/openstack-galera-1 \
  pod/openstack-galera-2 \
  -n openstack --timeout=180s

# 2. Delete ALL corrupted PVCs (corruption is on all nodes)
#    Leave the StatefulSet - the operator will keep it at 0 replicas
oc delete pvc mysql-db-openstack-galera-0 -n openstack
oc delete pvc mysql-db-openstack-galera-1 -n openstack
oc delete pvc mysql-db-openstack-galera-2 -n openstack

# 3. Restore from backup taken BEFORE corruption
#    skipIfAlreadyExists: true lets the restore skip the existing StatefulSet
#    and focus on recreating the deleted PVCs
cat <<'EOF' | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Restore
metadata:
  name: restore-corruption-recovery
  namespace: openstack
spec:
  restoreFlags:
    skipIfAlreadyExists: true
  source:
    type: Backup
    backup:
      name: pre-corruption-backup
      namespace: openstack
  restoreNamespace: openstack
EOF

# 4. Monitor restore
oc get restore restore-corruption-recovery -n openstack -w

# 5. After restore completes, scale Galera back to 3
oc scale statefulset openstack-galera -n openstack --replicas=3
oc scale deployment mariadb-operator-controller-manager -n openstack-operators --replicas=1
oc scale deployment openstack-operator-controller-manager -n openstack-operators --replicas=1

# 6. Check what was recreated
oc get statefulset,pvc -n openstack | grep galera

# 7. Check grastate.dat (informational - OSCP handles bootstrap automatically)
#    seqno: -1 and safe_to_bootstrap: 0 are EXPECTED for a restored live backup.
#    In RHOSO 18, the OSCP galera operator handles safe_to_bootstrap automatically.
#    No manual sed + pod delete is needed.
oc exec openstack-galera-0 -n openstack -c galera -- \
  cat /var/lib/mysql/grastate.dat 2>/dev/null || echo "Pod not ready yet - wait for it"

# Expected output:
# version: 2.1
# uuid:    <some-uuid>
# seqno:   -1           ← expected, not a problem
# safe_to_bootstrap: 0  ← OSCP operator handles this automatically

# 8. Wait for cluster to form
#    galera-0 boots with restored data, galera-1 and galera-2 SST from galera-0
sleep 120

# 9. Verify cluster health
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
      SHOW STATUS LIKE \"wsrep_cluster_size\";
      SHOW STATUS LIKE \"wsrep_local_state_comment\";"' 2>/dev/null || echo "Not ready"
done

# 10. Verify data is restored (test database should be back)
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "
    SHOW DATABASES;
    SELECT COUNT(*) AS row_count FROM backup_test.test_data;"'

# 11. Compare databases
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES;"' > /tmp/databases-after.txt
diff /tmp/databases-before.txt /tmp/databases-after.txt
```

**Expected Results:**
- All corrupted PVCs deleted and recreated from backup
- galera-0 PVC contains pre-corruption data; galera-1/2 created fresh by StatefulSet
- OSCP galera operator handles `safe_to_bootstrap` automatically (no manual intervention needed)
- galera-0 bootstraps with pre-corruption data; galera-1 and galera-2 join via SST
- `backup_test` database restored with all 5 rows
- All original databases present

**Note on `safe_to_bootstrap`:**
The restored `grastate.dat` will show `seqno: -1` and `safe_to_bootstrap: 0` — this
is expected (see Test 3 notes). In RHOSO 18, the OSCP galera operator handles the
bootstrap flag automatically. No manual `sed` + pod delete is required.


**Observed Results (February 18, 2026):**
```
Restore phases:
  Validation          → Completed
  PrimitiveMetadata   → Completed
  DataRestore         → Completed
  MetadataRestore     → Completed

Post-restore state:
  openstack-galera StatefulSet: 3/3
  galera-0 PVC age: 14m (restored)   galera-1/2 PVC age: 4m (fresh, SST from galera-0)

Cluster verification:
  galera-0: wsrep_cluster_size=3, wsrep_local_state_comment=Synced
  galera-1: wsrep_cluster_size=3, wsrep_local_state_comment=Synced
  galera-2: wsrep_cluster_size=3, wsrep_local_state_comment=Synced

Data verification:
  SELECT * FROM backup_test.test_data;
  id  value    created_at
  3   record1  2026-02-18 12:59:23
  6   record2  2026-02-18 12:59:23
  9   record3  2026-02-18 12:59:23
  12  record4  2026-02-18 12:59:23
  15  record5  2026-02-18 12:59:23

  → All 5 rows restored ✓
  → safe_to_bootstrap handled automatically by OSCP operator ✓
```

**After completion:** Run the full [Post-Recovery Verification](#post-recovery-verification-run-after-every-test)

---

### Test 5: Complete Data Loss (All PVCs Destroyed)

> **This scenario uses the same recovery procedure as Test 4.**
>
> The difference is the cause of data loss: in Test 4 the disaster is logical
> (SQL corruption replicated across all nodes); here the disaster is physical
> (PVCs deleted at the storage/infrastructure level — storage backend failure,
> accidental `oc delete pvc`, node loss with non-retained volumes).
>
> In both cases the end state before recovery is identical: all 3 PVCs are gone
> and must be restored from backup. Follow the [Test 4 recovery procedure](#test-4-data-corruption-recovery),
> substituting your most recent scheduled backup for `pre-corruption-backup`.
>
> **RPO note:** Data written after the last scheduled backup will be lost.
> Customers should be aware of their backup schedule and plan accordingly.



## Testing Order Recommendation

1. **Test 1** (Single PVC) - Proves Galera self-healing, builds confidence
2. **Test 2** (Two PVCs) - Proves SST works with minimum donors
3. **Test 3** (Restore to test namespace) - Validates backup without risk
4. **Test 4** (Data corruption / All PVCs lost) - Tests full restore from backup; covers both logical corruption and physical PVC loss scenarios
5. **Test 5** (All PVCs destroyed) - Same procedure as Test 4; skip if Test 4 already completed

---

## Known Considerations

### Cannot Disable Galera via `enabled: false` in RHOSO 18
OSCP validation prevents disabling Galera while other services remain enabled.
All of the following declare a hard dependency on Galera:
Keystone, Glance, Cinder, Nova, Neutron, Placement, Horizon, Barbican.

Attempting `oc patch openstackcontrolplane ... '{"spec":{"galera":{"enabled":false}}}'`
produces a validation error listing all dependent services.

**Solution for restore tests (RHOSO 18.0.2+):** `replicas: 0` is blocked by the
Galera CRD webhook. Scale down `mariadb-operator-controller-manager` and
`openstack-operator-controller-manager` first, then scale the StatefulSet directly
to 0. Add `skipIfAlreadyExists: true` to the Restore CR so the restore skips the
still-present StatefulSet and focuses on recreating the deleted PVCs. Scale the
StatefulSet back to 3 and restore both operators when done.

### Bootstrap After Restore
The backup PVC is snapshotted while MySQL is running (hook locks tables but does
not stop the process). As confirmed in Test 3, the restored `grastate.dat` will
always have `seqno: -1` and `safe_to_bootstrap: 0`.

**This is expected.** In RHOSO 18, the OSCP galera operator handles the
`safe_to_bootstrap` flag automatically — no manual `sed` + pod delete is required.
The operator detects that galera-0 needs to bootstrap and sets the flag internally
before starting the pod.

As confirmed in Test 4 (February 18, 2026): the cluster formed with all 3 nodes
`Synced` and `wsrep_cluster_size=3` without any manual bootstrap intervention.

> **Fallback (if operator does NOT handle it automatically):**
> ```bash
> oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
>   'sed -i "s/safe_to_bootstrap: 0/safe_to_bootstrap: 1/" /var/lib/mysql/grastate.dat'
> oc delete pod openstack-galera-0 -n openstack
> ```

### Namespace Deletion and Backup Metadata
Trilio for Kubernetes Backup CRs live in the same namespace as the workload. Deleting the
namespace destroys the backup metadata (not the data). Recovery requires:
1. Recreating the Target CR
2. Re-discovering backups from the target storage
3. Then restoring

**Recommendation:** Keep a copy of your Target CR definition outside the cluster
(e.g., in git) so you can recreate it after namespace loss.

### Backup Scope Limitation
This backup covers ONLY Galera-related resources (7 specific objects).
For full OpenStack namespace disaster recovery, you would need additional
backup plans covering all other OpenStack services.

---

## Production Restore Caveats

> **This section applies when restoring Galera in a live or partially-live
> OpenStack cluster — for example, restoring a backup taken 6 hours ago while
> VMs, volumes, and networks continued to exist and change.**

A Galera restore rolls back the database to a point in time. It does **not**
roll back the real infrastructure: compute hypervisors, Ceph storage, and OVN
networking continue running with their current state. The result is **state
divergence** — the DB and the real world disagree. The sections below describe
the impact per service and the audit commands to detect and repair divergence.

### Fundamental Rule

A Galera-only restore is safe when the cluster itself was down during the
outage period (so no new resources were created). If the cluster was live and
serving traffic during those 6 hours, expect divergence in every service.
The safest approach is to restore Galera **with the cluster scaled down to 0
replicas**, then audit each service before scaling OpenStack back up.

---

### Nova (Compute)

**What can go wrong:**

- **Ghost VMs:** VMs created 0–6 hours ago have DB records but were never
  booted (or were deleted on the hypervisor). Nova thinks they exist. Users
  see them in `openstack server list`. Any attempt to operate on them (start,
  stop, reboot) will fail with cryptic errors.

- **Orphaned VMs (more dangerous):** VMs that existed 6 hours ago but were
  deleted since then — they reappear in the DB. But the QEMU process on the
  compute node is gone. Worse: if those VMs had attached volumes, Nova will
  try to detach volumes that are no longer attached — corrupting Cinder state.

- **Placement allocation drift:** Every running VM has a resource allocation
  record in Placement (CPU, RAM, disk). After restore, Placement has
  6-hour-old allocations. Hosts that are actually full may appear to have
  headroom, causing Nova to over-schedule. Hosts with now-deleted VMs carry
  phantom allocations consuming capacity.

**Audit and repair commands:**

```bash
# List all instances Nova thinks exist (all projects)
openstack server list --all-projects -f json | jq -r '.[] | [.ID, .Name, .Status, .Host] | @tsv'

# Check each compute node for running VMs the compute node knows about
# (run on each compute host or via nova-compute logs)
# Ghost VMs will be in ACTIVE state in Nova DB but virsh list on the host
# will not show them:
for host in $(openstack compute service list --service nova-compute -f value -c Host); do
  echo "=== $host ==="
  openstack server list --all-projects --host "$host" -f value -c ID -c Name -c Status
done

# Heal Placement allocations (the most important command to run)
# This reconciles what Nova thinks is running with what Placement records
nova-manage cell_v2 heal_allocations --verbose --max-count 1000

# Verify instances known to Nova match what compute nodes report
nova-manage cell_v2 verify_instance --all-cells --uuids $(
  openstack server list --all-projects -f value -c ID | tr '\n' ',' | sed 's/,$//')

# Force Nova to re-sync instance states from hypervisor
# (triggers nova-compute to reconcile local state with DB)
# Restart nova-compute pods to trigger reconciliation:
oc rollout restart deployment -l component=nova-compute -n openstack

# Check Placement allocations for a resource provider (compute node)
for rp in $(openstack resource provider list -f value -c uuid); do
  alloc=$(openstack resource provider allocation show "$rp" -f json 2>/dev/null)
  echo "$rp: $alloc"
done
```

---

### Cinder (Block Storage)

**What can go wrong:**

- **Orphaned Ceph volumes:** Volumes created in the last 6 hours have RBD
  images in Ceph (`volumes/volume-<uuid>`) but no Cinder DB record. They
  consume storage indefinitely and are invisible to operators.

- **Ghost volumes (dangerous):** Volumes that existed 6 hours ago but were
  deleted since — they reappear in the Cinder DB. The Ceph RBD image is
  gone. If a user or Nova tries to attach them, Cinder will attempt to map
  an RBD image that does not exist. Results range from attach failure to
  Nova compute hanging waiting for a device that never appears.

- **Stale attachment records:** A volume attached 3 hours ago now appears
  unattached in Cinder, but the Nova instance still has the block device.
  If Cinder hands out that volume to a different VM, two VMs share one
  RBD image: **immediate data corruption.**

- **Volumes stuck in transitional states:** Any volume that was in
  `creating`, `deleting`, `attaching`, or `detaching` at backup time
  re-enters that state after restore. Cinder will not automatically
  resolve them — they need manual reset.

**Audit and repair commands:**

```bash
# List all volumes Cinder knows about
openstack volume list --all-projects -f json | \
  jq -r '.[] | [.ID, .Name, .Status, ."Attached to"] | @tsv'

# Find volumes in transitional/stuck states and reset them
for state in creating deleting attaching detaching error_deleting; do
  echo "=== Volumes in $state ==="
  openstack volume list --all-projects --status "$state" -f value -c ID -c Name
done

# Reset stuck volumes to a stable state (do this carefully)
# openstack volume set --state error <volume-id>   # mark as errored
# openstack volume set --state available <volume-id>  # if you know it's clean

# Compare Cinder DB records with actual Ceph RBD pool
# Find orphaned RBD images (in Ceph but not in Cinder DB):
CINDER_IDS=$(openstack volume list --all-projects -f value -c ID)
RBD_VOLS=$(rbd ls -p volumes 2>/dev/null | sed 's/volume-//')
comm -23 \
  <(echo "$RBD_VOLS" | sort) \
  <(echo "$CINDER_IDS" | sort)
# Output = UUIDs that exist in Ceph but have no Cinder record (orphaned)

# Find ghost volumes (in Cinder DB but not in Ceph):
comm -13 \
  <(echo "$RBD_VOLS" | sort) \
  <(echo "$CINDER_IDS" | sort)
# Output = UUIDs Cinder knows about but Ceph does not (delete these records)

# Check volume attachments — look for volumes attached to non-existent servers
openstack volume list --all-projects -f json | \
  jq -r '.[] | select(."Attached to" != []) | [.ID, (.["Attached to"][0].server_id // "none")] | @tsv' | \
  while read vol_id server_id; do
    if ! openstack server show "$server_id" &>/dev/null; then
      echo "ORPHANED ATTACHMENT: volume $vol_id attached to missing server $server_id"
    fi
  done
```

---

### Neutron / OVN (Networking)

**What can go wrong:**

- **Orphaned OVN resources:** Networks, subnets, ports, and routers created
  in the last 6 hours still have logical entries in OVN's Northbound DB
  (`ovn-nbctl`), but Neutron's DB has no record of them. OVN continues
  forwarding traffic for these "invisible" networks.

- **Missing port records for running VMs:** A VM created 3 hours ago had
  a Neutron port assigned. After restore, the port record is gone.
  Neutron will not manage that port. The OVN flow still exists so
  the VM stays connected, but: security group updates won't apply,
  floating IPs can't be assigned, and the port can't be reused or released.

- **Floating IP reassignment conflicts:** Floating IPs assigned in the
  last 6 hours are "available" in the DB but associated in OVN. New
  assignments may conflict. Existing associations may be silently broken.

**Audit and repair commands:**

```bash
# Check Neutron-OVN sync status
openstack network agent list  # look for ovn-controller agents

# Find ports Neutron knows about
openstack port list --all-projects -f value -c ID -c "Device Owner" -c Status | \
  grep -v "^$" > /tmp/neutron-ports.txt

# Find ports in OVN northbound DB
ovn-nbctl find Logical_Switch_Port | grep name | awk '{print $3}' | \
  tr -d '"' > /tmp/ovn-ports.txt

# Ports in OVN but not in Neutron (orphaned OVN entries)
comm -23 <(sort /tmp/ovn-ports.txt) <(sort /tmp/neutron-ports.txt)

# Ports in Neutron but not in OVN (missing OVN entries — will cause VM
# networking to break on next OVN sync)
comm -13 <(sort /tmp/ovn-ports.txt) <(sort /tmp/neutron-ports.txt)

# Force Neutron-OVN full re-sync
# This reconciles Neutron DB → OVN NB DB (one direction)
# WARNING: triggers OVN updates which may cause brief traffic interruption
oc exec -n openstack \
  $(oc get pods -n openstack -l component=neutron-api -o name | head -1) \
  -- neutron-ovn-db-sync-util --config-file /etc/neutron/neutron.conf \
     --config-file /etc/neutron/plugins/ml2/ml2_conf.ini \
     --ovn-neutron_sync_mode repair 2>/dev/null || \
  echo "Sync utility path may differ — check neutron pod for correct command"

# Check security groups are consistent
openstack security group list --all-projects -f value -c ID | while read sgid; do
  ovn-nbctl find ACL | grep -q "$sgid" || echo "SG $sgid has no OVN ACLs"
done
```

---

### Keystone (Identity)

**What can go wrong:**

- **Users and projects vanish:** Any user or project created in the last
  6 hours is gone from the DB. Their tokens still work until they expire
  (Fernet tokens are self-contained), but any new auth attempt fails.

- **Password rollback (security risk):** Users who changed their password
  in the last 6 hours have their old password restored. If the password
  change was a security rotation (e.g., after a credential leak), the
  leaked credential starts working again.

- **Service user credential drift:** OpenStack services (Nova, Neutron,
  Cinder, etc.) have service accounts in Keystone. If any service
  credentials were rotated in the last 6 hours, those services will
  fail to authenticate after restore.

- **Role assignment loss:** Role assignments added or removed in the
  last 6 hours are reverted. Users may regain access they were revoked,
  or lose access they were granted.

**Audit and repair commands:**

```bash
# List all users and projects (baseline after restore)
openstack user list --long -f json > /tmp/keystone-users-after.txt
openstack project list --long -f json > /tmp/keystone-projects-after.txt

# Force revocation of all outstanding Fernet tokens
# (prevents users from operating with pre-restore tokens that may have
# different roles than the restored DB)
# Rotate Fernet keys — old tokens signed with old keys become invalid:
oc exec -n openstack \
  $(oc get pods -n openstack -l component=keystone-api -o name | head -1) \
  -- keystone-manage fernet_rotate

# Restart Keystone to pick up the new keys
oc rollout restart deployment -l component=keystone-api -n openstack

# Verify all OpenStack services can still authenticate
# (check each service's keystone endpoint)
for svc in nova neutron cinder glance placement barbican; do
  echo -n "$svc: "
  openstack token issue --os-username "$svc" \
    --os-password "$(oc get secret osp-secret -n openstack -o jsonpath="{.data.${svc}Password}" | base64 -d)" \
    --os-project-name service \
    -f value -c id 2>/dev/null && echo "OK" || echo "AUTH FAILED"
done
```

---

### Barbican (Secret Store)

**What can go wrong:**

- **Key rotation rollback — potentially unrecoverable data loss:** If
  encryption keys for Cinder volumes, Nova ephemeral disks, or Swift
  containers were rotated in the last 6 hours, the DB now references
  the old keys. Data encrypted with the new keys cannot be decrypted.
  This is permanent — the new key material is gone with the restore.

- **Secret deletion reversal:** Secrets that were explicitly deleted
  (e.g., decommissioned API keys, expired certificates) reappear. If
  those secrets were deleted for security reasons, this is a regression.

- **Secret creation loss:** New secrets (TLS certificates, API keys,
  credentials) created in the last 6 hours are gone. Any service or
  VM relying on them will fail to authenticate or decrypt data.

**Audit and repair commands:**

```bash
# List all Barbican secrets after restore
openstack secret list --all -f json > /tmp/barbican-secrets-after.txt

# For encrypted Cinder volumes, check which secrets they reference
openstack volume list --all-projects -f json | \
  jq -r '.[] | select(.encrypted == true) | [.ID, .Name] | @tsv' | \
  while read vol_id vol_name; do
    echo "Encrypted volume: $vol_id ($vol_name)"
    # Attempt to get the key reference — if it fails the key is gone
    openstack volume show "$vol_id" -f json | jq -r '.encryption_key_id // "NO KEY"'
  done

# Check if encrypted volumes can still be attached (the real test)
# A volume that can no longer be decrypted will fail at attach time
# with: "Failed to open LUKS device"
# There is no pre-flight check — you discover this at attach time.
# Mitigation: keep a secure offline record of Barbican master keys.
```

> **Critical note:** If Barbican key rotation happened during the 6-hour
> window and you have encrypted volumes, treat those volumes as potentially
> unrecoverable. Attempt a test attach before declaring the restore complete.

---

### Placement (Resource Scheduler)

**What can go wrong:**

Placement stores the authoritative record of resource availability:
CPUs, RAM, disk, and custom traits per compute node. After restore,
Placement has 6-hour-old allocation data, causing:

- **Over-commitment:** Hosts appear to have capacity that is actually used.
  Nova schedules new VMs onto full hosts → they fail to boot.
- **Phantom allocations:** VMs deleted in the last 6 hours still consume
  capacity in Placement. Hosts appear full when they have headroom.
- **Missing allocations:** VMs created in the last 6 hours have no
  Placement allocation. Nova may double-schedule other VMs into that
  slot.

**Audit and repair commands:**

```bash
# The primary fix — reconcile Nova's view of running instances with Placement
nova-manage cell_v2 heal_allocations --verbose --max-count 1000

# Check resource provider inventory vs actual usage
openstack resource provider list -f json | jq -r '.[].uuid' | while read rp; do
  name=$(openstack resource provider show "$rp" -f value -c name)
  echo "=== $name ($rp) ==="
  openstack resource provider usage show "$rp" 2>/dev/null
done

# Find resource providers with impossible allocations (used > total)
openstack resource provider list -f json | jq -r '.[].uuid' | while read rp; do
  openstack resource provider allocation show "$rp" -f json 2>/dev/null | \
    jq -r 'to_entries[] | [.key, (.value.resources | to_entries[] | [.key, .value] | @tsv)] | @tsv'
done
```

---

### Glance (Image Service)

**What can go wrong:**

- **Orphaned image files:** Images uploaded in the last 6 hours have
  data stored in Ceph (`images/` pool) or Swift but no Glance DB record.
  The data occupies storage indefinitely.

- **Ghost image records:** Images deleted in the last 6 hours reappear
  in the DB. The Ceph/Swift object is gone. Attempting to boot from
  or download these images produces cryptic errors (404 from backend).

**Audit and repair commands:**

```bash
# List all images Glance knows about
openstack image list --all-projects -f json | \
  jq -r '.[] | [.ID, .Name, .Status] | @tsv' > /tmp/glance-images.txt

# Compare with Ceph images pool (if using Ceph backend)
rbd ls -p images > /tmp/ceph-images.txt

# Images in Ceph but not in Glance (orphaned — wasting storage)
comm -23 <(sort /tmp/ceph-images.txt) \
         <(awk '{print $1}' /tmp/glance-images.txt | sort)

# Images in Glance but not in Ceph (ghost — will fail on use)
openstack image list --all-projects -f value -c ID | while read img; do
  if ! rbd info images/"$img" &>/dev/null; then
    name=$(openstack image show "$img" -f value -c name 2>/dev/null)
    echo "GHOST IMAGE: $img ($name) — in DB but not in Ceph"
  fi
done

# Deactivate ghost images so they cannot be used
# openstack image deactivate <ghost-image-id>
```

---

### Heat (Orchestration)

**What can go wrong:**

- Stack operations completed in the last 6 hours are invisible to Heat.
  A stack that was `CREATE_COMPLETE` after 3 hours ago now shows as
  `CREATE_IN_PROGRESS` or doesn't exist at all.
- Resources created by Heat (VMs, networks, volumes) exist in the real
  world but Heat has no record they belong to a stack. Stack `UPDATE`
  or `DELETE` operations will fail because Heat cannot find its own
  resources.
- Stacks deleted in the last 6 hours reappear. Heat may try to manage
  resources that were cleaned up by the deletion.

**Audit and repair commands:**

```bash
# List all stacks Heat knows about
openstack stack list --all-projects -f json | \
  jq -r '.[] | [.ID, .StackName, .StackStatus] | @tsv'

# Check for stacks in stuck states
for state in CREATE_IN_PROGRESS UPDATE_IN_PROGRESS DELETE_IN_PROGRESS; do
  echo "=== Stacks in $state ==="
  openstack stack list --all-projects --filters "status=$state" -f value -c ID -c "Stack Name"
done

# For stacks in stuck states, abandon them (marks as abandoned, preserves resources)
# openstack stack abandon <stack-id>
# Then re-adopt resources if needed with openstack stack adopt
```

---

### Recommended Post-Restore Audit Sequence

Run these steps **before scaling OpenStack services back up**, or at minimum
before allowing users to perform write operations:

```bash
# ============================================================
# STEP 1: Verify Galera cluster health first
# ============================================================
for i in 0 1 2; do
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
      SHOW STATUS LIKE "wsrep_cluster_size";
      SHOW STATUS LIKE "wsrep_local_state_comment";"' 2>/dev/null
done

# ============================================================
# STEP 2: Heal Placement allocations (Nova)
# ============================================================
nova-manage cell_v2 heal_allocations --verbose --max-count 1000

# ============================================================
# STEP 3: Find and reset stuck Cinder volumes
# ============================================================
for state in creating deleting attaching detaching; do
  openstack volume list --all-projects --status "$state" -f value -c ID | while read vid; do
    echo "Resetting stuck volume $vid from state $state"
    openstack volume set --state error "$vid"
  done
done

# ============================================================
# STEP 4: Rotate Keystone Fernet keys (invalidate pre-restore tokens)
# ============================================================
oc exec -n openstack \
  $(oc get pods -n openstack -l component=keystone-api -o name | head -1) \
  -- keystone-manage fernet_rotate
oc rollout restart deployment -l component=keystone-api -n openstack

# ============================================================
# STEP 5: Force Neutron-OVN re-sync
# ============================================================
# See Neutron section above for the neutron-ovn-db-sync-util command

# ============================================================
# STEP 6: Verify OpenStack API health
# ============================================================
openstack catalog list
openstack compute service list
openstack volume service list
openstack network agent list

# ============================================================
# STEP 7: Check for ghost/orphaned resources
# ============================================================
# Run the per-service audit commands from the sections above.
# Prioritize: Cinder attachment audit (data corruption risk),
# then Nova ghost VM audit, then Glance ghost image audit.
```

> **Final note:** There is no tool that automatically resolves all divergence.
> The audit commands above detect problems; resolution requires manual
> judgment for each case (delete the ghost record? re-create the missing
> record? rebuild the resource?). Document every action taken so the
> incident can be reviewed and used to improve RPO/RTO targets.

---

## Key Metrics to Collect

For each test, record:

| Metric | Test 1 | Test 2 | Test 3 | Test 4 | Test 5 |
|--------|--------|--------|--------|--------|--------|
| Disaster execution time | | | N/A | | |
| Restore duration | N/A | N/A | | | |
| SST duration | | | N/A | | |
| Total recovery time | | | | | |
| Galera cluster healthy | | | | | |
| All databases present | | | | | |
| Replication working | | | | | |
| OpenStack pods healthy | | | N/A | | |
| Keystone auth working | | | N/A | | |
| Nova API working | | | N/A | | |
| Neutron API working | | | N/A | | |
| Glance API working | | | N/A | | |
| Cinder API working | | | N/A | | |

---

Document Version: 3.7
Created: February 17, 2026
Updated: February 18, 2026

