# Galera Backup Testing & Validation Checklist

## Purpose

This checklist ensures that the Galera backup solution is fully tested and validated before production deployment. Complete all tests in a non-production environment first.

---

## Pre-Testing Setup

### ✅ Environment Verification

- [ ] OpenShift cluster accessible
- [ ] RHOSO 18 deployed
- [ ] Galera cluster running with 3 nodes
- [ ] Trilio for Kubernetes installed
- [ ] `oc` CLI configured and authenticated
- [ ] Appropriate RBAC permissions

**Commands to verify:**
```bash
oc cluster-info
oc get pods -n openstack -l app=galera
oc get pods -n trilio-system
oc whoami
```

### ✅ Galera Cluster Health Baseline

- [ ] All 3 pods running and ready
- [ ] Cluster size = 3 on all nodes
- [ ] All nodes in "Synced" state
- [ ] Cluster status = "Primary" on all nodes
- [ ] No existing desync state

**Commands:**
```bash
# Check pods
oc get pods -n openstack -l app=galera

# Check cluster health
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
      SHOW STATUS LIKE \"wsrep_cluster_size\";
      SHOW STATUS LIKE \"wsrep_local_state_comment\";
      SHOW STATUS LIKE \"wsrep_cluster_status\";
      SHOW VARIABLES LIKE \"wsrep_desync\";"'
done
```

**Expected Results:**
- wsrep_cluster_size = 3
- wsrep_local_state_comment = Synced
- wsrep_cluster_status = Primary
- wsrep_desync = OFF

---

## Phase 1: Component Testing

### ✅ Test 1: Remote MySQL Connectivity

**Objective:** Verify galera-0 can connect to galera-1 and galera-2

**Steps:**

```bash
# Test connection to galera-1
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -h openstack-galera-1.openstack-galera -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1 AS test;"'

# Test connection to galera-2
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -h openstack-galera-2.openstack-galera -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1 AS test;"'

# Test retrieving state from galera-1
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -h openstack-galera-1.openstack-galera -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW STATUS LIKE \"wsrep_local_state_comment\";"'

# Test retrieving state from galera-2
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -h openstack-galera-2.openstack-galera -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW STATUS LIKE \"wsrep_local_state_comment\";"'
```

**Expected Results:**
- [ ] All connections succeed
- [ ] Query returns "1" or "Synced" as expected
- [ ] No DNS resolution errors
- [ ] No authentication errors

**Troubleshooting if fails:**
- Check service exists: `oc get svc openstack-galera -n openstack`
- Check DNS: `oc exec openstack-galera-0 -n openstack -c galera -- nslookup openstack-galera-1.openstack-galera`
- Verify password: Check `DB_ROOT_PASSWORD` environment variable

---

### ✅ Test 2: Manual Desync/Resync

**Objective:** Verify desync and resync operations work correctly

**⚠️ WARNING:** This test briefly removes galera-0 from cluster voting. Only run during maintenance window.

**Steps:**

```bash
# 1. Capture baseline
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
    SHOW STATUS LIKE \"wsrep_cluster_size\";
    SHOW STATUS LIKE \"wsrep_desync_count\";"'

# 2. Execute desync
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SET GLOBAL wsrep_desync = ON;"'

# 3. Wait 5 seconds for desync to take effect
sleep 5

# 4. Verify desync status
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
    SHOW VARIABLES LIKE \"wsrep_desync\";
    SHOW STATUS LIKE \"wsrep_desync_count\";
    SHOW STATUS LIKE \"wsrep_local_state\";"'

# 5. Verify other nodes still have quorum
for i in 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
    -e "SHOW STATUS LIKE \"wsrep_cluster_status\";"'
done

# 6. Execute resync (immediately to minimize impact)
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SET GLOBAL wsrep_desync = OFF;"'

# 7. Wait for resync to complete
sleep 10

# 8. Verify resync completed
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
    SHOW VARIABLES LIKE \"wsrep_desync\";
    SHOW STATUS LIKE \"wsrep_local_state_comment\";
    SHOW STATUS LIKE \"wsrep_cluster_size\";"'
```

**Expected Results:**
- [ ] After desync: wsrep_desync = ON
- [ ] After desync: wsrep_desync_count incremented
- [ ] During desync: galera-1 and galera-2 show "Primary" status
- [ ] After resync: wsrep_desync = OFF
- [ ] After resync: wsrep_local_state_comment = Synced
- [ ] After resync: wsrep_cluster_size = 3

**Troubleshooting if fails:**
- If desync doesn't take effect: Check for long-running transactions
- If resync takes > 60 seconds: Check network connectivity between nodes
- If cluster loses quorum during desync: Cluster was already degraded

---

### ✅ Test 3: Table Lock/Unlock

**Objective:** Verify table locking works and doesn't cause deadlocks

**Steps:**

```bash
# 1. Lock tables
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "FLUSH TABLES WITH READ LOCK;"'

# 2. Verify lock is active (in separate connection)
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW STATUS LIKE \"Com_lock_tables\";"'

# 3. Try a write operation (should be blocked/fail)
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'timeout 5 mysql -u root -p"${DB_ROOT_PASSWORD}" \
  -e "CREATE DATABASE IF NOT EXISTS test_write;" 2>&1' || echo "Write blocked as expected"

# 4. Unlock tables
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "UNLOCK TABLES;"'

# 5. Verify write now works
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "
    CREATE DATABASE IF NOT EXISTS test_write;
    DROP DATABASE test_write;"'
```

**Expected Results:**
- [ ] Lock succeeds without error
- [ ] Write operations are blocked while locked
- [ ] Unlock succeeds
- [ ] Write operations work after unlock

---

### ✅ Test 4: Trilio for Kubernetes Target Validation

**Objective:** Verify Trilio for Kubernetes can connect to backup storage

**Steps:**

```bash
# 1. Check target exists
oc get target -n openstack

# 2. Describe target for details
oc describe target <your-target-name> -n openstack

# 3. Check target status
oc get target <your-target-name> -n openstack -o jsonpath='{.status.status}'

# 4. Verify credentials
oc get secret <credentials-secret-name> -n openstack

# 5. Test target connectivity (if supported by Trilio for Kubernetes version)
# Some versions have a validation endpoint
oc describe target <your-target-name> -n openstack | grep -i "validation\|status\|available"
```

**Expected Results:**
- [ ] Target exists and is in "Available" status
- [ ] Credentials secret exists
- [ ] No connection errors in target description

---

## Phase 2: Hook Testing

### ✅ Test 5: Deploy and Verify Hook

**Steps:**

```bash
# 1. Deploy hook
oc apply -f galera-backup-hook.yaml

# 2. Verify hook was created
oc get hook galera-backup-hook -n openstack

# 3. Check hook specification
oc describe hook galera-backup-hook -n openstack

# 4. Verify selector matches galera-0
oc get pods -n openstack -l apps.kubernetes.io/pod-index=0
```

**Expected Results:**
- [ ] Hook CR created successfully
- [ ] Hook shows correct namespace (openstack)
- [ ] Selector matches only galera-0 pod
- [ ] Pre and post commands are present

---

## Phase 3: Backup Testing

### ✅ Test 6: Deploy BackupPlan

**Steps:**

```bash
# 1. Verify target name is correct in YAML
grep "name: trilio-target" galera-backup-plan.yaml

# 2. Deploy BackupPlan
oc apply -f galera-backup-plan.yaml

# 3. Verify BackupPlan created
oc get backupplan openstack-galera-backup -n openstack

# 4. Check BackupPlan details
oc describe backupplan openstack-galera-backup -n openstack

# 5. Verify hook is referenced correctly
oc get backupplan openstack-galera-backup -n openstack -o yaml | grep -A 10 "hooks:"

# 6. Verify PVC exclusions
oc get backupplan openstack-galera-backup -n openstack -o yaml | grep -A 5 "excludeResources:"
```

**Expected Results:**
- [ ] BackupPlan CR created successfully
- [ ] Hook reference is correct
- [ ] PVC exclusions include galera-1 and galera-2
- [ ] Target reference is correct

---

### ✅ Test 7: First Manual Backup (Controlled Test)

**Objective:** Perform first real backup with monitoring

**⚠️ WARNING:** This test will briefly desync galera-0. Only run during maintenance window.

**Steps:**

```bash
# 1. Set up log monitoring (in separate terminal)
oc logs -f openstack-galera-0 -n openstack -c galera | grep trilio-backup

# 2. Create manual backup
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Backup
metadata:
  name: galera-test-$(date +%Y%m%d-%H%M%S)
  namespace: openstack
  labels:
    test: first-backup
spec:
  type: Full
  backupPlan:
    name: openstack-galera-backup
    namespace: openstack
EOF

# 3. Watch backup progress
oc get backup -n openstack -w

# 4. After backup completes, check detailed status
BACKUP_NAME=$(oc get backups -n openstack -l test=first-backup --sort-by=.metadata.creationTimestamp -o name | tail -1)
oc describe $BACKUP_NAME -n openstack

# 5. Verify cluster health after backup
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
      SHOW STATUS LIKE \"wsrep_cluster_size\";
      SHOW STATUS LIKE \"wsrep_local_state_comment\";
      SHOW VARIABLES LIKE \"wsrep_desync\";"'
done

# 6. Check hook execution logs
oc logs openstack-galera-0 -n openstack -c galera --since=10m | grep trilio-backup
```

**Expected Results:**
- [ ] Backup status progresses: New → Running → Completed
- [ ] Hook logs show successful pre-hook execution
- [ ] Hook logs show desync verification passed
- [ ] Hook logs show tables locked
- [ ] Snapshot completed
- [ ] Hook logs show successful post-hook execution
- [ ] Hook logs show tables unlocked
- [ ] Hook logs show node resynced
- [ ] Final backup status = "Available"
- [ ] Cluster size = 3 on all nodes after backup
- [ ] All nodes show "Synced" state after backup
- [ ] wsrep_desync = OFF on galera-0 after backup
- [ ] Total backup time < 5 minutes

**Key Metrics to Record:**
- Pre-hook execution time: _______
- Desync verification time: _______
- Snapshot time: _______
- Post-hook execution time: _______
- Total backup time: _______

---

### ✅ Test 8: Verify Backup Artifacts

**Steps:**

```bash
# 1. Check backup CR status
oc get backup <backup-name> -n openstack -o yaml

# 2. Verify completion percentage
oc get backup <backup-name> -n openstack -o jsonpath='{.status.percentageComplete}'

# 3. Check what was backed up
oc get backup <backup-name> -n openstack -o jsonpath='{.status.backupComponents}' | jq

# 4. Verify PVCs backed up (should only be galera-0)
oc get backup <backup-name> -n openstack -o yaml | grep -i pvc

# 5. Check backup size/metadata
oc describe backup <backup-name> -n openstack | grep -i "size\|status\|complete"
```

**Expected Results:**
- [ ] percentageComplete = 100
- [ ] Status = "Available"
- [ ] Only galera-0 PVC is included
- [ ] galera-1 and galera-2 PVCs are excluded
- [ ] Backup metadata includes StatefulSet, Services, ConfigMaps

---

### ✅ Test 9: Consecutive Backup Test

**Objective:** Verify multiple backups work without issues

**Steps:**

```bash
# Run 3 backups back-to-back
for i in 1 2 3; do
  echo "=== Backup $i of 3 ==="

  cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Backup
metadata:
  name: galera-consecutive-test-$i
  namespace: openstack
spec:
  type: Full
  backupPlan:
    name: openstack-galera-backup
    namespace: openstack
EOF

  # Wait for backup to complete
  echo "Waiting for backup to complete..."
  while true; do
    STATUS=$(oc get backup galera-consecutive-test-$i -n openstack -o jsonpath='{.status.status}' 2>/dev/null)
    if [ "$STATUS" = "Available" ] || [ "$STATUS" = "Failed" ]; then
      echo "Backup $i status: $STATUS"
      break
    fi
    echo -n "."
    sleep 5
  done

  # Verify cluster health between backups
  CLUSTER_SIZE=$(oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
    -e "SHOW STATUS LIKE \"wsrep_cluster_size\";"' | awk '{print $2}')

  echo "Cluster size after backup $i: $CLUSTER_SIZE"

  if [ "$i" -lt 3 ]; then
    echo "Waiting 30 seconds before next backup..."
    sleep 30
  fi
done

# Verify all completed
oc get backups -n openstack | grep consecutive-test
```

**Expected Results:**
- [ ] All 3 backups complete successfully
- [ ] Each backup takes approximately same time
- [ ] Cluster maintains size=3 between backups
- [ ] No accumulated degradation

---

## Phase 4: Failure Scenario Testing

### ✅ Test 10: Pod Restart During Backup

**Objective:** Verify backup survives pod restart

**Steps:**

```bash
# 1. Start backup
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Backup
metadata:
  name: galera-restart-test
  namespace: openstack
spec:
  type: Full
  backupPlan:
    name: openstack-galera-backup
    namespace: openstack
EOF

# 2. Wait for backup to enter Running state
while true; do
  STATUS=$(oc get backup galera-restart-test -n openstack -o jsonpath='{.status.status}' 2>/dev/null)
  if [ "$STATUS" = "Running" ]; then
    echo "Backup is running, restarting galera-2..."
    break
  fi
  sleep 1
done

# 3. Delete galera-2 pod (non-backup node)
oc delete pod openstack-galera-2 -n openstack

# 4. Watch backup continue
oc get backup galera-restart-test -n openstack -w

# 5. Verify final state
oc describe backup galera-restart-test -n openstack

# 6. Check cluster recovered
for i in 0 1 2; do
  oc get pod openstack-galera-$i -n openstack
done
```

**Expected Results:**
- [ ] Backup completes successfully despite pod restart
- [ ] galera-2 pod restarts and rejoins cluster
- [ ] Final cluster size = 3
- [ ] All nodes synced

---

### ✅ Test 11: Backup Cancellation and Cleanup

**Objective:** Verify cleanup works if backup is cancelled

**Steps:**

```bash
# 1. Start backup
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Backup
metadata:
  name: galera-cancel-test
  namespace: openstack
spec:
  type: Full
  backupPlan:
    name: openstack-galera-backup
    namespace: openstack
EOF

# 2. Wait for it to start
sleep 5

# 3. Delete backup (cancel it)
oc delete backup galera-cancel-test -n openstack --force --grace-period=0

# 4. Check if node is still desynced
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW VARIABLES LIKE \"wsrep_desync\";"'

# 5. If stuck, manually clean up
if [ "$(oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW VARIABLES LIKE \"wsrep_desync\";" | awk "{print \$2}"')" = "ON" ]; then

  echo "Node stuck desynced, cleaning up..."
  oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" \
    -e "UNLOCK TABLES; SET GLOBAL wsrep_desync = OFF;"'
fi

# 6. Verify recovery
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
    SHOW VARIABLES LIKE \"wsrep_desync\";
    SHOW STATUS LIKE \"wsrep_local_state_comment\";"'
```

**Expected Results:**
- [ ] Backup deletion succeeds
- [ ] Post-hook runs automatically OR manual cleanup works
- [ ] Node returns to Synced state
- [ ] wsrep_desync = OFF

---

### ✅ Test 12: Pre-Hook Failure Handling

**Objective:** Verify backup aborts cleanly if pre-hook fails

**Steps:**

```bash
# 1. Artificially create a condition that will fail pre-hook
# (e.g., set cluster to degraded state by stopping galera-2)
oc patch openstackcontrolplane openstack-controlplane -n openstack \
  --type=merge -p '{"spec":{"galera":{"templates":{"openstack":{"replicas":2}}}}}'
sleep 30

# 2. Try to create backup (should fail pre-flight checks)
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Backup
metadata:
  name: galera-prehook-fail-test
  namespace: openstack
spec:
  type: Full
  backupPlan:
    name: openstack-galera-backup
    namespace: openstack
EOF

# 3. Watch it fail
oc get backup galera-prehook-fail-test -n openstack -w

# 4. Check logs for error
oc logs openstack-galera-0 -n openstack -c galera --since=2m | grep trilio-backup

# 5. Verify node NOT desynced
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
  -e "SHOW VARIABLES LIKE \"wsrep_desync\";"'

# 6. Restore cluster via OSCP
oc patch openstackcontrolplane openstack-controlplane -n openstack \
  --type=merge -p '{"spec":{"galera":{"templates":{"openstack":{"replicas":3}}}}}'
sleep 60

# 7. Verify cluster health
for i in 0 1 2; do
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN \
    -e "SHOW STATUS LIKE \"wsrep_cluster_size\";"'
done
```

**Expected Results:**
- [ ] Backup fails with "Hook execution failed" or similar
- [ ] Pre-hook log shows "Cluster is degraded" error
- [ ] Node is NOT desynced (pre-hook aborted early)
- [ ] Cluster remains operational on 2 nodes
- [ ] Cluster recovers when scaled back to 3

---

## Phase 5: Restore Testing

### ✅ Test 13: Restore to Different Namespace

**Objective:** Verify restore works without affecting production

**Steps:**

```bash
# 1. Create test namespace
oc create namespace galera-restore-test

# 2. Select a successful backup
BACKUP_TO_RESTORE=$(oc get backups -n openstack --sort-by=.metadata.creationTimestamp -o name | grep -v test | tail -1)
echo "Restoring from: $BACKUP_TO_RESTORE"

# 3. Create restore
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Restore
metadata:
  name: galera-restore-test-$(date +%Y%m%d)
  namespace: galera-restore-test
spec:
  restoreFlags:
    skipIfAlreadyExists: true
    useOCPNamespaceUIDRange: true  # Critical: remaps file ownership to target namespace UID range
  source:
    type: Backup
    backup:
      name: $(echo $BACKUP_TO_RESTORE | cut -d'/' -f2)
      namespace: openstack
  restoreNamespace: galera-restore-test
EOF

# 4. Monitor restore
oc get restore -n galera-restore-test -w

# 5. Check restored resources
oc get all -n galera-restore-test

# 6. Verify PVC was restored
oc get pvc -n galera-restore-test

# 7. Check if pod starts (may fail due to different namespace configuration)
oc get pods -n galera-restore-test -l app=galera

# 8. Cleanup test namespace
oc delete namespace galera-restore-test
```

**Expected Results:**
- [ ] Restore completes with status "Completed"
- [ ] PVC is restored to test namespace
- [ ] StatefulSet/other resources are restored
- [ ] Production cluster (openstack namespace) is unaffected

---

### ✅ Test 14: Full Disaster Recovery Simulation

**⚠️ CRITICAL WARNING:** This test is DESTRUCTIVE. Only run in isolated test environment, NOT production.

> **See `galera-real-disaster-tests.md` for the complete, validated disaster recovery procedures.** That document contains step-by-step instructions, observed results, known considerations, and production caveats from real test executions. Follow it manually — do not run automated scripts.

**Objective:** Simulate complete data loss and full recovery

**Steps:**

```bash
# 1. Identify a known-good backup
BACKUP_TO_RESTORE=$(oc get backups -n openstack --field-selector status.status=Available --sort-by=.metadata.creationTimestamp -o name | tail -1)
echo "Will restore from: $BACKUP_TO_RESTORE"

# 2. Document current database contents
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES;"' > /tmp/pre-restore-dbs.txt

# 3. Scale down Galera cluster via OSCP (do NOT use oc scale - operator will override it)
oc patch openstackcontrolplane openstack-controlplane -n openstack \
  --type=merge -p '{"spec":{"galera":{"templates":{"openstack":{"replicas":0}}}}}'

# 4. Wait for pods to terminate
oc get pods -n openstack -l app=galera -w

# 5. Delete PVCs (DESTRUCTIVE - this is the "disaster")
oc delete pvc mysql-db-openstack-galera-0 -n openstack
oc delete pvc mysql-db-openstack-galera-1 -n openstack
oc delete pvc mysql-db-openstack-galera-2 -n openstack

# 6. Verify PVCs are gone
oc get pvc -n openstack | grep galera

# 7. Create restore
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Restore
metadata:
  name: galera-full-restore-$(date +%Y%m%d)
  namespace: openstack
spec:
  restoreFlags:
    skipIfAlreadyExists: true
  source:
    type: Backup
    backup:
      name: $(echo $BACKUP_TO_RESTORE | cut -d'/' -f2)
      namespace: openstack
  restoreNamespace: openstack
EOF

# 8. Monitor restore (will take 30-120 minutes depending on data size)
oc get restore -n openstack -w

# 9. After restore completes, scale up cluster via OSCP
oc patch openstackcontrolplane openstack-controlplane -n openstack \
  --type=merge -p '{"spec":{"galera":{"templates":{"openstack":{"replicas":3}}}}}'

# 10. Wait for pods to start
oc get pods -n openstack -l app=galera -w

# 11. Verify cluster health
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
      SHOW STATUS LIKE \"wsrep_cluster_size\";
      SHOW STATUS LIKE \"wsrep_local_state_comment\";
      SHOW STATUS LIKE \"wsrep_cluster_status\";"' 2>/dev/null || echo "Pod not ready"
done

# 12. Verify database contents restored
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW DATABASES;"' > /tmp/post-restore-dbs.txt

# 13. Compare
diff /tmp/pre-restore-dbs.txt /tmp/post-restore-dbs.txt
```

**Expected Results:**
- [ ] Restore completes successfully
- [ ] All 3 PVCs are recreated
- [ ] All 3 pods start and join cluster
- [ ] Cluster size = 3
- [ ] All nodes in "Synced" state
- [ ] Cluster status = "Primary"
- [ ] Database contents match pre-disaster state

**Key Metrics to Record:**
- Time to restore PVC: _______
- Time to bootstrap cluster: _______
- Total recovery time: _______

---

## Phase 6: Production Readiness

### ✅ Test 15: Schedule Configuration (Optional)

> **Note:** No schedule is configured in `galera-backup-plan.yaml` by default. Skip this test if you are not using automated scheduling. Only run if you have created a Schedule CR manually.

**Steps:**

```bash
# 1. Verify schedule deployed
oc get schedule <your-schedule-name> -n openstack

# 2. Check schedule details
oc describe schedule <your-schedule-name> -n openstack

# 3. Verify cron expression
oc get schedule <your-schedule-name> -n openstack -o jsonpath='{.spec.schedule}'

# 4. Check suspend status (should be false)
oc get schedule <your-schedule-name> -n openstack -o jsonpath='{.spec.suspend}'
```

**Expected Results:**
- [ ] Schedule exists
- [ ] Cron expression matches your intended schedule
- [ ] suspend = false
- [ ] References correct BackupPlan

---

### ✅ Test 16: Performance Under Load (Optional)

**Objective:** Verify backup works during simulated production load

**Steps:**

```bash
# 1. Start a write workload (in background)
oc exec openstack-galera-1 -n openstack -c galera -- bash -c '
for i in {1..1000}; do
  mysql -u root -p"${DB_ROOT_PASSWORD}" -e "
    CREATE DATABASE IF NOT EXISTS loadtest;
    USE loadtest;
    CREATE TABLE IF NOT EXISTS loadtable (id INT, data VARCHAR(255));
    INSERT INTO loadtable VALUES ($i, \"data-$i\");
  " 2>/dev/null
  sleep 1
done
' &

WORKLOAD_PID=$!

# 2. Wait for workload to start
sleep 10

# 3. Trigger backup during load
cat <<EOF | oc apply -f -
apiVersion: triliovault.trilio.io/v1
kind: Backup
metadata:
  name: galera-load-test
  namespace: openstack
spec:
  type: Full
  backupPlan:
    name: openstack-galera-backup
    namespace: openstack
EOF

# 4. Monitor backup
oc get backup galera-load-test -n openstack -w

# 5. Stop workload after backup completes
kill $WORKLOAD_PID 2>/dev/null || true

# 6. Cleanup test database
oc exec openstack-galera-0 -n openstack -c galera -- bash -c \
  'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS loadtest;"'
```

**Expected Results:**
- [ ] Backup completes successfully despite concurrent writes
- [ ] Backup time is comparable to idle test
- [ ] Cluster remains healthy throughout
- [ ] Workload continues on galera-1 and galera-2

---

## Final Checklist

### ✅ Pre-Production Sign-Off

- [ ] All tests in Phase 1-3 passed
- [ ] At least 3 successful consecutive backups
- [ ] At least 1 successful restore test
- [ ] Backup duration < 5 minutes consistently
- [ ] Cluster health maintained across all tests
- [ ] Post-hook recovery verified
- [ ] Failure scenarios tested
- [ ] Schedule configured (if using automated backups)
- [ ] Monitoring/alerting plan defined
- [ ] Runbook reviewed by operations team
- [ ] Escalation procedures documented

### ✅ Documentation Complete

- [ ] galera-backup-hook.yaml deployed
- [ ] galera-backup-plan.yaml deployed
- [ ] galera-backup-runbook.md available to ops team
- [ ] This testing checklist completed
- [ ] Results documented and reviewed

### ✅ Production Deployment Approval

**Approvals Required:**

- [ ] Platform Engineer: _______________
- [ ] Database Administrator: _______________
- [ ] OpenStack Administrator: _______________
- [ ] Operations Manager: _______________

**Date Approved for Production:** _______________

---

## Test Results Summary

### Test Environment Details

- OpenShift Version: _______________
- RHOSO Version: _______________
- Trilio for Kubernetes Version: _______________
- Galera Cluster Size: _______________
- Database Size: _______________
- Test Date: _______________

### Key Metrics from Testing

| Metric | Value |
|--------|-------|
| Average backup duration | _____ seconds |
| Average desync duration | _____ seconds |
| Average resync duration | _____ seconds |
| Backup success rate | _____ % |
| Test backups completed | _____ |
| Test restores completed | _____ |
| Restore duration | _____ minutes |

### Issues Encountered

1. _______________________________________
2. _______________________________________
3. _______________________________________

### Recommendations

1. _______________________________________
2. _______________________________________
3. _______________________________________

---

## Post-Deployment Validation

### First Week After Production Deployment

- [ ] Day 1: Manual backup successful
- [ ] Day 2: Scheduled backup successful
- [ ] Day 3: Scheduled backup successful
- [ ] Day 4: Scheduled backup successful
- [ ] Day 5: Scheduled backup successful
- [ ] Day 6: Scheduled backup successful
- [ ] Day 7: Scheduled backup successful + test restore

### Monitoring Validation

- [ ] Backup success metrics collected
- [ ] Backup duration metrics collected
- [ ] Cluster health metrics monitored
- [ ] Alerts triggered appropriately (if any failures)
- [ ] Logs accessible and searchable

---

**Document Version:** 1.3
**Last Updated:** February 19, 2026
**Next Review:** Quarterly or after any major changes
