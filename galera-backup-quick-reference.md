# Galera Backup - Quick Reference Card

## 🚀 Quick Start

```bash
# Check backup status
oc get backups -n openstack

# Trigger manual backup
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Backup
metadata:
  name: galera-manual-$(date +%Y%m%d-%H%M%S)
  namespace: openstack
spec:
  type: Full
  backupPlan:
    name: openstack-galera-backup
    namespace: openstack
EOF

# Monitor backup
oc get backup -n openstack -w

# Check logs
oc logs -f openstack-galera-0 -n openstack -c galera | grep trilio-backup
```

---

## 🏥 Health Checks

### Quick Cluster Health

```bash
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
      SHOW STATUS LIKE \"wsrep_cluster_size\";
      SHOW STATUS LIKE \"wsrep_local_state_comment\";"'
done
```

**Expected:**
- wsrep_cluster_size = 3
- wsrep_local_state_comment = Synced

### Check if Node is Stuck Desynced

```bash
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW VARIABLES LIKE \"wsrep_desync\";"'
```

**Expected:** wsrep_desync = OFF

---

## 🔧 Common Operations

### View Recent Backups

```bash
oc get backups -n openstack --sort-by=.metadata.creationTimestamp
```

### Check Specific Backup Status

```bash
oc describe backup <backup-name> -n openstack
```

### View Backup Logs

```bash
# Last 2 hours
oc logs openstack-galera-0 -n openstack -c galera --since=2h | grep trilio-backup

# Specific backup (check timestamp)
oc logs openstack-galera-0 -n openstack -c galera --since-time="2026-02-17T02:00:00Z" | grep trilio-backup
```

### Suspend/Resume Schedule

> No schedule is configured by default. If you have added one, use its name below.

```bash
# Suspend (disable automated backups)
oc patch schedule <your-schedule-name> -n openstack \
  --type=merge -p '{"spec":{"suspend":true}}'

# Resume
oc patch schedule <your-schedule-name> -n openstack \
  --type=merge -p '{"spec":{"suspend":false}}'
```

---

## 🚨 Emergency Procedures

### Node Stuck Desynced

**Symptoms:** Backup finished but node still shows wsrep_desync=ON

**Fix:**
```bash
# Resync manually
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" \
  -e "UNLOCK TABLES; SET GLOBAL wsrep_desync = OFF;"'

# Clean up markers
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'rm -f /tmp/backup_*'

# Verify
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW STATUS LIKE \"wsrep_local_state_comment\";"'
```

### Backup Hanging (> 5 minutes)

**Fix:**
```bash
# 1. Check status
oc get backup <backup-name> -n openstack

# 2. Delete hung backup
oc delete backup <backup-name> -n openstack --force --grace-period=0

# 3. Manual cleanup (if needed)
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" \
  -e "UNLOCK TABLES; SET GLOBAL wsrep_desync = OFF;"'

# 4. Verify cluster health
for i in 0 1 2; do
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
    -e "SHOW STATUS LIKE \"wsrep_cluster_size\";"' 2>/dev/null || echo "Pod $i down"
done
```

### Backup Fails Pre-Flight Check

**Symptoms:** Backup fails immediately with "Hook execution failed"

**Diagnosis:**
```bash
# Check logs for error
oc logs openstack-galera-0 -n openstack -c galera --tail=50 | grep trilio-backup

# Common causes:
# - Cluster degraded (< 3 nodes)
# - Node not synced
# - Node already desynced (stuck from previous backup)
```

**Fix:** Resolve the underlying issue (see logs), then retry backup

---

## 💾 Restore Operations

### Quick Restore to Test Namespace

```bash
# 1. Create test namespace
oc create namespace galera-restore-test

# 2. Create restore
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Restore
metadata:
  name: restore-test-$(date +%Y%m%d)
  namespace: openstack
spec:
  source:
    type: Backup
    backup:
      name: <backup-name>
      namespace: openstack
  restoreNamespace: galera-restore-test
  skipIfAlreadyExists: false
EOF

# 3. Monitor
oc get restore -n openstack -w
```

### Full Disaster Recovery

**⚠️ DESTRUCTIVE - Only use in actual disaster scenario**

```bash
# See galera-real-disaster-tests.md for the complete, validated procedure
# Follow the steps manually — do not use automated scripts
```

---

## 📊 Monitoring

### Key Metrics

| Metric | Normal | Warning | Critical |
|--------|--------|---------|----------|
| Backup duration | < 1 min | > 5 min | > 10 min |
| Desync duration | < 20s | > 60s | > 300s |
| Cluster size during backup | 3 | 2 | < 2 |
| Node resync time | < 60s | > 120s | > 300s |
| Backup success rate | 100% | < 95% | < 90% |

### Daily Checklist

- [ ] Check last backup succeeded: `oc get backups -n openstack | head -5`
- [ ] Verify cluster healthy: `oc get pods -n openstack -l app=galera`
- [ ] Review backup logs for warnings: `oc logs openstack-galera-0 -n openstack -c galera --since=24h | grep -i warn`

---

## 📝 Key Configuration

### Backup Window
- **Scheduled:** Intentionally, there is no schedule set
- **Duration:** ~15 seconds (desync window)
- **Impact:** Minimal - 2 nodes remain active

### Retention
- **Policy:** Intentionally, there is no retention set
- **Rotation:** Automatic via Trilio for Kubernetes

### Resources Backed Up
- ✅ openstack-galera-0 PVC (50GB)
- ✅ StatefulSet, Services, ConfigMaps
- ❌ galera-1 PVC (excluded)
- ❌ galera-2 PVC (excluded)

### Safety Features
- Pre-flight cluster health checks
- Desync verification loop (prevents premature snapshot)
- Double write protection (desync + table locks)
- Automatic post-backup recovery
- Quorum maintenance (2/3 nodes remain voting)

---

## 🆘 Escalation

### When to Escalate

**Immediate (P1):**
- Backup fails 2+ consecutive times
- Node stuck desynced > 10 minutes
- Cluster loses quorum
- Production restore needed

**Next Business Day (P3):**
- Single backup failure (retry succeeded)
- Backup duration > 5 minutes
- Minor hook warnings

### Contacts

**Trilio for Kubernetes Support:**
- Email: support@trilio.io
- Portal: https://trilio.my.site.com/io/s/
- Docs: https://docs.trilio.io

**Red Hat Support:**
- Portal: https://access.redhat.com
- Emergency: Contact TAM

---

## 📁 Files Reference

| File | Purpose |
|------|---------|
| `galera-backup-hook.yaml` | Hook with desync/resync logic |
| `galera-backup-plan.yaml` | BackupPlan + Schedule configuration |
| `galera-health-check.sh` | Read-only cluster + OpenStack health check |
| `galera-real-disaster-tests.md` | Disaster recovery procedures and test results |
| `galera-backup-runbook.md` | Day-to-day operational reference |
| `galera-backup-testing-checklist.md` | Pre-production testing guide |
| `why-this-way.md` | Design rationale — the *why* behind every decision |

---

## 🔍 Troubleshooting Decision Tree

```
Backup failed?
├─ Check logs: oc logs openstack-galera-0 -n openstack -c galera | grep trilio-backup
│
├─ "Cluster is degraded"?
│  └─ Fix cluster health first, then retry
│
├─ "Node is not in Synced state"?
│  └─ Wait for node to sync, then retry
│
├─ "Node is already desynced"?
│  └─ Run emergency cleanup (see above), then retry
│
├─ "Desync verification FAILED"?
│  └─ Check connection count, network, or schedule during lower traffic
│
└─ Other error?
   └─ Check Trilio for Kubernetes logs: oc logs -n trilio-system -l app=k8s-triliovault
```

---

## 💡 Tips & Best Practices

1. **Always check logs** - Most issues are clearly indicated in hook logs
2. **Monitor first backup** - Watch logs in real-time for the first few backups
3. **Test restores monthly** - Verify backups are actually restorable
4. **Keep runbook updated** - Document any new issues encountered
5. **Schedule wisely** - 2 AM is low-traffic, adjust if needed for your workload
6. **Monitor metrics** - Set up alerts for backup failures and long durations

---

**Quick Access:**
- Logs: `oc logs -f openstack-galera-0 -n openstack -c galera | grep trilio-backup`
- Status: `oc get backups -n openstack`
- Health: `oc get pods -n openstack -l app=galera`

**Last Updated:** February 18, 2026
**Version:** 1.1
