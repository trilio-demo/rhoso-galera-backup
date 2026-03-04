# Galera Backup & Restore - Operational Runbook

## Quick Reference

**Environment:** RHOSO 18 / OpenShift
**Cluster:** 3-node Galera (openstack-galera-0, -1, -2)
**Backup Tool:** Trilio for Kubernetes
**Backup Node:** openstack-galera-0 (designated)
**Namespace:** openstack

---

## Pre-Deployment Checklist

### 1. Verify Trilio for Kubernetes Installation

```bash
# Check Trilio for Kubernetes operator is running
oc get pods -n trilio-system

# Verify Trilio for Kubernetes CRDs are installed
oc get crd | grep triliovault

# Check Trilio for Kubernetes version
oc get deployment k8s-triliovault-control-plane -n trilio-system -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### 2. Create Trilio for Kubernetes Target

```bash
# Example: S3-compatible target
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Target
metadata:
  name: trilio-target
  namespace: openstack
spec:
  type: ObjectStore
  vendor: AWS  # or Other for S3-compatible
  objectStoreCredentials:
    url: "https://s3.example.com"
    bucketName: "galera-backups"
    region: "us-east-1"
    credentialSecret:
      name: s3-credentials
      namespace: openstack
  thresholdCapacity: 1000Gi
EOF

# Validate target
oc get target trilio-target -n openstack
oc describe target trilio-target -n openstack
```

### 3. Verify Galera Cluster Health

```bash
# Check all 3 pods are running
oc get pods -n openstack -l app=galera

# Verify cluster size on each node
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
    -e "SHOW STATUS LIKE \"wsrep_cluster_size\";"'
done

# Verify all nodes are synced
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
    -e "SHOW STATUS LIKE \"wsrep_local_state_comment\";"'
done
```

### 4. Test Remote MySQL Connectivity (Critical!)

```bash
# From galera-0, test connection to galera-1
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -h openstack-galera-1.openstack-galera -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;"'

# From galera-0, test connection to galera-2
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -h openstack-galera-2.openstack-galera -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;"'
```

### 5. Test Desync/Resync Operations

```bash
# Test desync (DO NOT do this during production hours)
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SET GLOBAL wsrep_desync = ON;"'

# Verify desync status
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW VARIABLES LIKE \"wsrep_desync\";"'

# Check desync count incremented
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW STATUS LIKE \"wsrep_desync_count\";"'

# Resync immediately
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SET GLOBAL wsrep_desync = OFF;"'

# Verify resync
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW STATUS LIKE \"wsrep_local_state_comment\";"'
```

---

## Deployment Steps

### Step 1: Deploy Hook

```bash
# Apply the hook configuration
oc apply -f galera-backup-hook.yaml

# Verify hook was created
oc get hook galera-backup-hook -n openstack
oc describe hook galera-backup-hook -n openstack
```

### Step 2: Deploy BackupPlan

**IMPORTANT:** Before applying, update the target name in `galera-backup-plan.yaml`:

```yaml
spec:
  backupConfig:
    target:
      name: trilio-target  # <-- Replace with YOUR target name
      namespace: openstack
```

```bash
# Apply the BackupPlan
oc apply -f galera-backup-plan.yaml

# Verify BackupPlan was created
oc get backupplan openstack-galera-backup -n openstack
oc describe backupplan openstack-galera-backup -n openstack
```

### Step 3: Test with Manual Backup

```bash
# Create a test backup
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

# Monitor backup progress
oc get backup -n openstack -w

# Watch logs in real-time (in separate terminal)
oc logs -f openstack-galera-0 -n openstack -c galera | grep trilio-backup
```

### Step 4: Enable Automated Schedule (Optional)

> **Note:** No schedule is configured in `galera-backup-plan.yaml` by default. Backups are triggered manually. If you want automated backups, create a Schedule CR separately and reference the `openstack-galera-backup` BackupPlan.

```bash
# Verify your schedule was created
oc get schedule <your-schedule-name> -n openstack
oc describe schedule <your-schedule-name> -n openstack
```

---

## Daily Operations

### Check Backup Status

```bash
# List all backups
oc get backups -n openstack

# Get detailed status of latest backup
LATEST_BACKUP=$(oc get backups -n openstack --sort-by=.metadata.creationTimestamp -o name | tail -1)
oc describe $LATEST_BACKUP -n openstack

# Check backup logs
oc logs openstack-galera-0 -n openstack -c galera --since=2h | grep trilio-backup
```

### Verify Backup Completed Successfully

```bash
# Check backup status (should be "Available")
oc get backup <backup-name> -n openstack -o jsonpath='{.status.status}'

# Check completion percentage
oc get backup <backup-name> -n openstack -o jsonpath='{.status.percentageComplete}'

# View backup details
oc describe backup <backup-name> -n openstack
```

### Monitor Cluster Health

```bash
# Quick health check
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
    -e "SHOW STATUS LIKE \"wsrep_%\";" | grep -E "(cluster_size|local_state_comment|cluster_status)"'
done
```

---

## Troubleshooting

### Issue: Backup Fails with "Hook Execution Failed"

**Symptoms:**
- Backup status shows "Failed"
- Error mentions hook execution

**Diagnosis:**

```bash
# Check hook logs
oc logs openstack-galera-0 -n openstack -c galera | grep trilio-backup | tail -50

# Check if node is stuck desynced
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW VARIABLES LIKE \"wsrep_desync\";"'

# Check backup CR for error details
oc describe backup <failed-backup-name> -n openstack
```

**Resolution:**

```bash
# If node is stuck desynced, manually resync
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" \
  -e "SET GLOBAL wsrep_desync = OFF; UNLOCK TABLES;"'

# Verify resync completed
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW STATUS LIKE \"wsrep_local_state_comment\";"'

# Delete failed backup and retry
oc delete backup <failed-backup-name> -n openstack
```

### Issue: Backup Times Out

**Symptoms:**
- Backup stuck in "Running" state for > 5 minutes
- No progress updates

**Diagnosis:**

```bash
# Check if hook is stuck
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'ls -la /tmp/backup_* 2>/dev/null'

# Check desync status
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW VARIABLES LIKE \"wsrep_desync\"; \
      SHOW STATUS LIKE \"wsrep_local_state_comment\";"'

# Check Trilio for Kubernetes operator logs
oc logs -n trilio-system -l app=k8s-triliovault --tail=100
```

**Resolution:**

```bash
# 1. Manually unlock and resync
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" \
  -e "UNLOCK TABLES; SET GLOBAL wsrep_desync = OFF;"'

# 2. Clean up marker files
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'rm -f /tmp/backup_*'

# 3. Delete stuck backup
oc delete backup <stuck-backup-name> -n openstack --force --grace-period=0

# 4. Verify cluster health before retrying
# (run cluster health check from above)
```

### Issue: Cluster Loses Quorum During Backup

**Symptoms:**
- OpenStack APIs return errors
- Multiple Galera nodes show "Non-Primary" status

**Diagnosis:**

```bash
# Check cluster status on all nodes
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
    -e "SHOW STATUS LIKE \"wsrep_cluster_status\"; \
        SHOW STATUS LIKE \"wsrep_cluster_size\";"' 2>/dev/null || echo "Pod unavailable"
done
```

**Resolution:**

This should auto-recover when post-hook runs. If not:

```bash
# 1. Manually resync galera-0
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" \
  -e "UNLOCK TABLES; SET GLOBAL wsrep_desync = OFF;"'

# 2. Wait 30 seconds for cluster to reform

# 3. If still no quorum, bootstrap from the most up-to-date node
# Find node with highest seqno
for i in 0 1 2; do
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'cat /var/lib/mysql/grastate.dat' 2>/dev/null
done

# Bootstrap from the node with highest seqno (usually galera-1 or galera-2)
# This is a LAST RESORT - contact Trilio/Red Hat support first
```

### Issue: Post-Hook Doesn't Run

**Symptoms:**
- Backup completes but galera-0 stays desynced
- Tables remain locked
- Node never resyncs

**Diagnosis:**

```bash
# Check if backup completed
oc get backup <backup-name> -n openstack -o jsonpath='{.status.status}'

# Check if node is still desynced
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW VARIABLES LIKE \"wsrep_desync\";"'

# Check for lock markers
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'ls -la /tmp/backup_*'
```

**Resolution:**

```bash
# Manual cleanup (equivalent to post-hook)
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" \
  -e "UNLOCK TABLES; SET GLOBAL wsrep_desync = OFF;"'

# Clean up markers
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'rm -f /tmp/backup_*'

# Verify resync
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW STATUS LIKE \"wsrep_local_state_comment\";"'
```

### Issue: Desync Verification Times Out

**Symptoms:**
- Hook logs show "Desync verification FAILED"
- Backup aborts before snapshot

**Diagnosis:**

```bash
# Check what the desync status actually is
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW VARIABLES LIKE \"wsrep_desync\"; \
      SHOW STATUS LIKE \"wsrep_desync_count\"; \
      SHOW STATUS LIKE \"wsrep_local_state\";"'

# Check active connections
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'ss -ant | grep :3306 | grep ESTAB | wc -l'
```

**Possible Causes & Solutions:**

1. **High connection count** - Too many active connections preventing desync
   ```bash
   # Check what's connected
   oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
     'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW PROCESSLIST;"'

   # Consider scheduling backups during low-traffic window
   ```

2. **Large transactions in progress**
   ```bash
   # Check for long-running transactions
   oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
     'mysql -u root -p"${DB_ROOT_PASSWORD}" -e \
     "SELECT * FROM information_schema.innodb_trx \
      WHERE trx_started < NOW() - INTERVAL 60 SECOND;"'
   ```

3. **Network issues between nodes**
   ```bash
   # Test connectivity
   oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
     'for i in 1 2; do ping -c 3 openstack-galera-$i.openstack-galera; done'
   ```

---

## Restore Operations

### Full Cluster Restore

**When to use:** Complete data loss, all nodes corrupted

**Prerequisites:**
- Identify the backup to restore from
- Ensure OpenStack services can tolerate downtime
- Have a rollback plan

**Steps:**

```bash
# 1. Scale down Galera cluster
# NOTE: On RHOSO 18.0.2+ (operator v1.0.3+), replicas: 0 is blocked at the CRD level.
# You must scale down both operators first, then scale the StatefulSet directly.
oc scale deployment mariadb-operator-controller-manager -n openstack-operators --replicas=0
oc scale deployment openstack-operator-controller-manager -n openstack-operators --replicas=0
oc scale statefulset openstack-galera -n openstack --replicas=0

# 2. Wait for all pods to terminate
oc get pods -n openstack -l app=galera -w

# 3. Delete corrupted PVCs (DANGEROUS - ensure you have backups!)
oc delete pvc mysql-db-openstack-galera-0 -n openstack
oc delete pvc mysql-db-openstack-galera-1 -n openstack
oc delete pvc mysql-db-openstack-galera-2 -n openstack

# 4. Create Restore CR
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Restore
metadata:
  name: restore-galera-$(date +%Y%m%d-%H%M)
  namespace: openstack
spec:
  restoreFlags:
    skipIfAlreadyExists: true
  source:
    type: Backup
    backup:
      name: <backup-name-to-restore>
      namespace: openstack
  restoreNamespace: openstack
EOF

# 5. Monitor restore progress
oc get restore -n openstack -w

# 6. Wait for restore to complete (status: "Completed")
oc get restore restore-galera-$(date +%Y%m%d-%H%M) -n openstack

# 7. Scale up Galera cluster and restore operators
oc scale statefulset openstack-galera -n openstack --replicas=3
oc scale deployment mariadb-operator-controller-manager -n openstack-operators --replicas=1
oc scale deployment openstack-operator-controller-manager -n openstack-operators --replicas=1

# 8. Wait for all pods to be Running
oc get pods -n openstack -l app=galera -w

# 9. Verify cluster formed and all nodes synced
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
    -e "SHOW STATUS LIKE \"wsrep_cluster_size\"; \
        SHOW STATUS LIKE \"wsrep_local_state_comment\"; \
        SHOW STATUS LIKE \"wsrep_cluster_status\";"'
done

# 10. Verify database contents
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES;"'

# 11. Test OpenStack API connectivity
# (use your OpenStack client commands here)
```

**Expected Timeline:**
- PVC deletion: 1-2 minutes
- Restore from backup: 30-120 minutes (depending on size)
- Cluster bootstrap: 5-10 minutes
- **Total: 1-3 hours**

### Point-in-Time Restore to Different Namespace (Testing)

**When to use:** Test restores without affecting production

```bash
# Create test namespace
oc create namespace galera-restore-test

# Restore to test namespace
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Restore
metadata:
  name: restore-test-$(date +%Y%m%d)
  namespace: galera-restore-test
spec:
  restoreFlags:
    skipIfAlreadyExists: true
    useOCPNamespaceUIDRange: true  # Critical: remaps file ownership to target namespace UID range
  source:
    type: Backup
    backup:
      name: <backup-name>
      namespace: openstack
  restoreNamespace: galera-restore-test
EOF

# Monitor and verify
oc get restore -n openstack -w
oc get pods -n galera-restore-test
```

---

## Monitoring & Alerting

### Key Metrics to Monitor

1. **Backup Success Rate**
   - Alert if backup fails 2 consecutive times

2. **Backup Duration**
   - Normal: 15-60 seconds (snapshot only)
   - Warning: > 5 minutes
   - Critical: > 10 minutes

3. **Desync Duration**
   - Normal: < 20 seconds
   - Warning: > 60 seconds
   - Critical: > 300 seconds

4. **Cluster Size During Backup**
   - Alert if drops below 2 nodes

5. **Node Resync Time**
   - Normal: < 60 seconds
   - Warning: > 120 seconds

### Log Queries

```bash
# Check all backup operations in last 24 hours
oc logs openstack-galera-0 -n openstack -c galera --since=24h | grep trilio-backup

# Check for errors
oc logs openstack-galera-0 -n openstack -c galera --since=24h | grep -i "error\|failed\|timeout"

# Get backup duration from logs
oc logs openstack-galera-0 -n openstack -c galera --since=24h | grep "Backup duration"

# Check desync/resync operations
oc logs openstack-galera-0 -n openstack -c galera --since=24h | grep -E "Desync|Resync"
```

---

## Maintenance Procedures

### Temporarily Disable Backups

> **Note:** No schedule is configured in `galera-backup-plan.yaml` by default. These steps only apply if you have added a Schedule CR manually.

```bash
# Suspend the schedule
oc patch schedule <your-schedule-name> -n openstack \
  --type=merge -p '{"spec":{"suspend":true}}'

# Verify
oc get schedule <your-schedule-name> -n openstack -o jsonpath='{.spec.suspend}'
```

### Re-enable Backups

```bash
# Resume the schedule
oc patch schedule <your-schedule-name> -n openstack \
  --type=merge -p '{"spec":{"suspend":false}}'
```

### Clean Up Old Backups (Manual)

```bash
# List all backups sorted by age
oc get backups -n openstack --sort-by=.metadata.creationTimestamp

# Delete specific backup
oc delete backup <backup-name> -n openstack

# Delete all backups older than 30 days (CAREFUL!)
# This is a destructive operation - verify before running
for backup in $(oc get backups -n openstack -o name); do
  AGE=$(oc get $backup -n openstack -o jsonpath='{.metadata.creationTimestamp}')
  # Add logic to compare dates and delete if needed
done
```

### Update Hook Configuration

```bash
# Edit hook
oc edit hook galera-backup-hook -n openstack

# Or apply updated YAML
oc apply -f galera-backup-hook.yaml

# Test with manual backup after changes
```

---

## Recovery Scenarios

### Scenario: Node Fails During Backup

**Likelihood:** Very low (~0.0001% in 15-second window)

**Symptoms:**
- One Galera pod terminates unexpectedly during backup
- Cluster temporarily loses quorum (2 nodes minimum, but 1 is desynced)

**Automatic Recovery:**
The post-hook will automatically resync galera-0, restoring quorum within 15-30 seconds.

**Verification:**
```bash
# Check backup completed
oc get backup <backup-name> -n openstack

# Check cluster recovered
for i in 0 1 2; do
  oc get pod openstack-galera-$i -n openstack 2>/dev/null || echo "Pod $i down"
done

# Check quorum
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW STATUS LIKE \"wsrep_cluster_size\"; \
      SHOW STATUS LIKE \"wsrep_cluster_status\";"'
```

**No action needed unless backup actually failed.**

### Scenario: Backup Job Crashes (Post-Hook Never Runs)

**Likelihood:** Rare (once a year maybe)

**Symptoms:**
- Backup CR stuck or deleted
- galera-0 still shows `wsrep_desync = ON`
- Tables still locked
- OpenStack APIs timeout

**Manual Recovery:**

```bash
# 1. Verify the issue
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW VARIABLES LIKE \"wsrep_desync\";"'

# 2. Manually run post-hook operations
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" \
  -e "UNLOCK TABLES; SET GLOBAL wsrep_desync = OFF;"'

# 3. Clean up markers
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'rm -f /tmp/backup_*'

# 4. Verify recovery
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW STATUS LIKE \"wsrep_local_state_comment\";"'
```

**Recovery time: 1-2 minutes**

---

## Contact & Escalation

**For Trilio for Kubernetes issues:**
- Trilio for Kubernetes Documentation: https://docs.trilio.io
- Support: support@trilio.io
- KB: https://support.trilio.io

**For RHOSO/Galera issues:**
- Red Hat Documentation: https://docs.redhat.com/en/documentation/red_hat_openstack_services_on_openshift/18.0
- Support: Open case at https://access.redhat.com
- Emergency: Contact your Red Hat TAM

**For OpenShift issues:**
- OpenShift Documentation: https://docs.openshift.com
- Support: Open case at https://access.redhat.com

---

## Document Metadata

**Version:** 1.1
**Last Updated:** February 19, 2026
**Maintained By:** Platform Team
**Review Cycle:** Quarterly

