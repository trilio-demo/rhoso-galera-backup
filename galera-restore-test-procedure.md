# Galera Restore: Lab Test Procedure (hook v3)

**Status: lab procedure, not yet confirmed.** Run it only on a lab cluster you can
rebuild. Once confirmed, the results replace the "Restore Operations" section of
`galera-backup-runbook.md`.

## What we are testing

With hook v3 the backup contains the 3 Galera PVCs. One of them (the pod the hook
quiesced, normally `openstack-galera-2`) is application-consistent: FTWRL was held
while the snapshot was taken. The other two are crash-consistent: they were
snapshotted while MariaDB kept writing.

On restore, the mariadb-operator bootstraps the cluster from the node with the
highest Galera seqno (`findBestCandidate` in `galera_controller.go`; the seqno
comes from `grastate.dat`, or from `mysqld --wsrep-recover` when grastate says -1,
which is the case for crash-consistent copies). The active pod kept committing
while the quiesced pod was frozen, so **the operator will normally bootstrap from a
crash-consistent copy**, and the consistent copy becomes a joiner.

Two outcomes are possible, and the lab has to tell us which one we get:

- **Plan A works:** InnoDB crash recovery on the crash-consistent copy succeeds,
  the cluster forms, OpenStack is consistent. Customer procedure stays "restore
  the whole backup, choose nothing". The consistent copy is insurance.
- **Plan A fails:** the bootstrap node does not come up or data is inconsistent.
  Then we force the bootstrap from the consistent copy (Plan B below).

**The test is only meaningful if there are writes during the backup.** In an idle
cluster all three seqnos are equal, the tie-break picks `galera-2`, and Plan A
passes for the wrong reason.

## 0. Safety net (do this first, every time)

```bash
# a) Logical dump from the active pod, copied out of the cluster
ACTIVE=$(oc get svc openstack -n openstack -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}')
echo "active pod: $ACTIVE"
oc exec -n openstack $ACTIVE -c galera -- bash -c \
  'mariadb-dump -u root -p"${DB_ROOT_PASSWORD}" --all-databases --single-transaction --routines --events' \
  > galera-safety-$(date +%Y%m%d-%H%M).sql
ls -lh galera-safety-*.sql

# b) Manual VolumeSnapshots of the 3 PVCs with the cluster stopped
oc scale deployment mariadb-operator-controller-manager -n openstack-operators --replicas=0
oc scale deployment openstack-operator-controller-manager -n openstack-operators --replicas=0
oc scale statefulset openstack-galera -n openstack --replicas=0
oc get pods -n openstack -l app=galera   # wait until none

VSC=$(oc get volumesnapshotclass -o jsonpath='{.items[0].metadata.name}')
for i in 0 1 2; do
cat <<EOF | oc apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: safety-galera-$i
  namespace: openstack
spec:
  volumeSnapshotClassName: $VSC
  source:
    persistentVolumeClaimName: mysql-db-openstack-galera-$i
EOF
done
oc get volumesnapshot -n openstack -w   # wait for READYTOUSE=true on all 3

oc scale statefulset openstack-galera -n openstack --replicas=3
oc scale deployment mariadb-operator-controller-manager -n openstack-operators --replicas=1
oc scale deployment openstack-operator-controller-manager -n openstack-operators --replicas=1
oc get pods -n openstack -l app=galera -w   # all 3 Running and Ready
```

## 1. Backup with writes in flight

Start a write loop, then trigger the backup, then stop the loop when the backup is
Completed.

```bash
# terminal 1: writes
while true; do
  openstack flavor create --ram 64 --disk 1 --vcpus 1 trilio-test-$RANDOM -f value -c id | xargs -I{} openstack flavor delete {}
  sleep 1
done

# terminal 2: watch the active endpoint, it must never disappear
oc get endpoints openstack -n openstack -w

# terminal 3: trigger the backup and follow it
oc create -f - <<EOF
apiVersion: triliovault.trilio.io/v1
kind: Backup
metadata:
  name: galera-test-$(date +%Y%m%d-%H%M)
  namespace: openstack
spec:
  type: Full
  backupPlan:
    name: openstack-galera-backup
    namespace: openstack
EOF
oc get backup -n openstack -w
```

Hook logs, only one pod does the work:

```bash
oc logs -n openstack -l app=galera -c galera --tail=200 | grep trilio-backup
```

Record which pod was quiesced (`Selected as backup pod`) and which was active.
You will need both in step 4.

## 2. Plan A: restore everything, choose nothing

Follow `galera-backup-runbook.md` "Full Cluster Restore" steps 1 to 8 (scale
operators and StatefulSet to 0, delete the 3 PVCs, create the Restore CR, wait for
Completed, scale back up). Then:

```bash
# which node did the operator bootstrap from?
oc get galera openstack -n openstack -o jsonpath='{.status.attributes}' | python3 -m json.tool
oc logs -n openstack-operators deployment/mariadb-operator-controller-manager | grep -i -E "bootstrap|seqno|safe_to"

# cluster health
for i in 0 1 2; do
  echo "=== galera-$i ==="
  oc exec openstack-galera-$i -n openstack -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "SHOW STATUS LIKE \"wsrep_cluster_size\"; SHOW STATUS LIKE \"wsrep_local_state_comment\";"'
done

# OpenStack sanity
openstack flavor list
openstack server list --all-projects
```

**Plan A passes** if: cluster size 3, all Synced, OpenStack API answers and the
data looks right. Report the bootstrap node and how long the cluster took.

**Plan A fails** if: the bootstrap node crash-loops, `wsrep-recover` cannot find a
position, or the cluster forms but OpenStack data is wrong. Go to Plan B. Do not
retry Plan A first.

## 3. Identify the consistent copy (forensics)

Three independent ways. Use at least two and make sure they agree.

**a) The hook log from step 1.** `Selected as backup pod (ordinal N, ...)`.

**b) The Service selector in the backup.** The backup contains Service
`openstack`; its selector says which pod was active at backup time. The hook rule
is "highest ordinal that is not the active": active 0 or 1 → consistent copy is
`galera-2`; active 2 → `galera-1`. Read it from the restored Service before the
operator rewrites it (right after the Restore is Completed, before scaling up):

```bash
oc get svc openstack -n openstack -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}'
```

If the Restore did not replace the existing Service (`skipIfAlreadyExists`), check
the Service YAML in the backup from the T4K UI (target browser) instead.

**c) The seqno on disk.** With the StatefulSet at 0, mount each restored PVC and
recover its position. The consistent copy has the LOWEST seqno (it was frozen
first) and its `grastate.dat`, if present, has a real seqno instead of -1.

```bash
for i in 0 1 2; do
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: galera-inspect-$i
  namespace: openstack
spec:
  restartPolicy: Never
  serviceAccountName: galera-openstack   # same SCC/UID as the real pods, so file ownership matches
  containers:
  - name: inspect
    image: $(oc get statefulset openstack-galera -n openstack -o jsonpath='{.spec.template.spec.containers[0].image}')
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /var/lib/mysql
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: mysql-db-openstack-galera-$i
EOF
done
oc get pods -n openstack | grep galera-inspect   # all 3 Running

for i in 0 1 2; do
  echo "=== PVC galera-$i ==="
  oc exec -n openstack galera-inspect-$i -- cat /var/lib/mysql/grastate.dat
  oc exec -n openstack galera-inspect-$i -- bash -c \
    'mysqld --wsrep-recover --datadir=/var/lib/mysql --user=mysql --skip-networking --wsrep-cluster-address=gcomm://localhost 2>&1 | grep -i "recovered position"'
done
```

Write down the result as `CONSISTENT=<0|1|2>`.

## 4. Plan B: force the bootstrap from the consistent copy

Still with operators and StatefulSet at 0 and the inspect pods running:

```bash
CONSISTENT=2   # from step 3

# consistent copy: mark it safe to bootstrap
oc exec -n openstack galera-inspect-$CONSISTENT -- bash -c \
  'cat /var/lib/mysql/grastate.dat; sed -i "s/^safe_to_bootstrap:.*/safe_to_bootstrap: 1/" /var/lib/mysql/grastate.dat; cat /var/lib/mysql/grastate.dat'
# if grastate.dat does not exist or has seqno -1, create it from the recovered position:
#   uuid: <uuid from wsrep-recover>  seqno: <seqno>  safe_to_bootstrap: 1

# the other two: remove galera state so they SST from the bootstrap node
for i in 0 1 2; do
  [ $i -eq $CONSISTENT ] && continue
  oc exec -n openstack galera-inspect-$i -- rm -f /var/lib/mysql/grastate.dat /var/lib/mysql/gvwstate.dat
done

# release the PVCs and start the cluster
oc delete pod -n openstack galera-inspect-0 galera-inspect-1 galera-inspect-2
oc scale statefulset openstack-galera -n openstack --replicas=3
oc scale deployment mariadb-operator-controller-manager -n openstack-operators --replicas=1
oc scale deployment openstack-operator-controller-manager -n openstack-operators --replicas=1
oc get pods -n openstack -l app=galera -w
```

The operator honours `safe_to_bootstrap` before looking at seqnos, so it must
bootstrap from `galera-$CONSISTENT`. Confirm with the same checks as in step 2 and
report: bootstrap node, time to cluster size 3, SST duration for the two joiners.

## 5. Rollback if the cluster will not come back

Fast path (minutes): recreate the 3 PVCs from the safety VolumeSnapshots of step 0.

```bash
oc scale statefulset openstack-galera -n openstack --replicas=0   # operators already at 0
oc delete pvc -n openstack mysql-db-openstack-galera-0 mysql-db-openstack-galera-1 mysql-db-openstack-galera-2
SC=$(oc get galera openstack -n openstack -o jsonpath='{.spec.storageClass}')
SIZE=$(oc get galera openstack -n openstack -o jsonpath='{.spec.storageRequest}')
for i in 0 1 2; do
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-db-openstack-galera-$i
  namespace: openstack
spec:
  storageClassName: $SC
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: $SIZE
  dataSource:
    apiGroup: snapshot.storage.k8s.io
    kind: VolumeSnapshot
    name: safety-galera-$i
EOF
done
oc scale statefulset openstack-galera -n openstack --replicas=3
oc scale deployment mariadb-operator-controller-manager -n openstack-operators --replicas=1
oc scale deployment openstack-operator-controller-manager -n openstack-operators --replicas=1
```

Slow path (always works): delete the 3 PVCs, let the operator create an empty
cluster, load the dump from step 0 into the active pod:

```bash
ACTIVE=$(oc get svc openstack -n openstack -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}')
oc exec -i -n openstack $ACTIVE -c galera -- bash -c 'mysql -u root -p"${DB_ROOT_PASSWORD}"' < galera-safety-<timestamp>.sql
```

## 6. What to report back

1. Pre-implementation checks from the PR: all passed, or which one failed.
2. Backup: quiesced pod, active pod, backup duration, endpoint never disappeared (yes/no).
3. Plan A: bootstrap node, time to cluster size 3, OpenStack sanity result.
4. If Plan B was needed: which forensics method(s) identified the consistent copy, whether they agreed, bootstrap node, SST time.
5. Anything that did not match this document.
