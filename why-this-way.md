# Why This Way — Design Rationale for Galera Backup on RHOSO 18

This document explains the reasoning behind every significant design decision in
this backup solution. If you are wondering why something is done a certain way,
the answer is here.

---

## Why back up only galera-0's PVC?

All three Galera nodes contain identical data at all times. Galera is a
synchronous multi-master cluster — every write is committed on all nodes before
it is acknowledged to the client. There is no primary/replica lag; the data on
galera-0, galera-1, and galera-2 is always the same.

Backing up all three PVCs would triple storage consumption and triple backup
duration with zero additional protection. A single consistent snapshot of
galera-0 is sufficient to restore the entire cluster.

On restore, galera-1 and galera-2 start with empty PVCs. They detect this
automatically and request a State Snapshot Transfer (SST) from galera-0. Within
minutes they are fully populated and the cluster is back to 3/3 Synced.

---

## Why use a Hook at all?

Trilio for Kubernetes snapshots a PVC at the storage layer. Without intervention, MySQL
could have dirty pages in memory that have not yet been flushed to disk at the
moment the snapshot is taken. The result would be a backup that is not crash-
consistent — it would require InnoDB crash recovery on restore and could
potentially be unrecoverable.

The Hook ensures the snapshot is taken at a moment when:
- All writes have been flushed to disk (`FLUSH TABLES WITH READ LOCK`)
- The node is no longer receiving new writes from the cluster (`wsrep_desync = ON`)
- The PVC state is fully consistent

---

## Why desync the node before locking the tables?

The sequence matters. Desync first, then lock.

If you lock tables while the node is still part of the cluster write path,
incoming Galera replication events will queue up waiting for the lock to be
released. On a busy cluster this queue can grow very fast, and if it exceeds
the `gcs.fc_limit` threshold Galera will apply flow control and pause writes
on all nodes — causing an outage.

By desyncing first, galera-0 is removed from the cluster write path before the
lock is applied. The remaining two nodes (galera-1 and galera-2) continue
serving all writes with no interruption. The lock on galera-0 affects nobody.

---

## Why verify that desync actually took effect before locking?

`SET GLOBAL wsrep_desync = ON` is asynchronous. It instructs Galera to begin
the desync process, but the node is not guaranteed to be fully desynced
immediately. The hook polls `wsrep_desync_count` in a loop until it increments,
confirming the desync is in effect before proceeding to lock.

Skipping this verification could result in locking the tables while the node is
still receiving replication events, which is exactly what we are trying to avoid.

---

## Why run the Hook on galera-0 specifically?

galera-0 is the only node whose PVC is included in the backup. The Hook must
run on the same node that is being snapshotted — otherwise we would be locking
and desyncing a different node from the one being backed up, which would achieve
nothing.

The Hook CR uses a pod selector (`apps.kubernetes.io/pod-index: "0"`) to target
galera-0 exclusively. galera-1 and galera-2 are untouched and continue serving
traffic throughout the backup window.

---

## Why is the backup window only ~15 seconds?

The "backup window" — the period during which galera-0 is locked and
unavailable — is the time between `FLUSH TABLES WITH READ LOCK` and
`UNLOCK TABLES`. Trilio for Kubernetes's CSI snapshot mechanism operates at the storage
layer and completes in seconds regardless of data size (it is a pointer
operation, not a copy). The actual data transfer to the Backup Target happens
after the snapshot is taken and the lock is released.

The cluster serves writes through galera-1 and galera-2 throughout this window.
The only impact is that galera-0 is temporarily removed from the write quorum,
reducing redundancy from 3 nodes to 2 for ~15 seconds.

---

## Why `replicas: 0` instead of `enabled: false` to scale down Galera?

RHOSO 18 runs on the OpenStack Control Plane Operator (OSCP). The
`openstackcontrolplane` CR has a validation webhook that checks service
dependencies before accepting changes.

Setting `enabled: false` on the Galera service is rejected by the webhook
because Keystone, Glance, Cinder, Nova, Neutron, Placement, Horizon, and
Barbican all declare Galera as a hard dependency. The webhook refuses the change
to prevent accidentally disabling a service that other services depend on.

Setting `replicas: 0` achieves the same result — zero running pods — without
triggering the dependency check. The service remains "enabled" in the operator's
view but has no running instances.

---

## Why `oc patch openstackcontrolplane` instead of `oc scale statefulset`?

The Galera StatefulSet is fully managed by the OSCP operator. If you scale the
StatefulSet directly with `oc scale`, the operator detects the drift and
immediately reconciles it back to the desired replica count. Your scale operation
is overwritten within seconds.

The only reliable way to scale Galera up or down is to update the desired state
in the `openstackcontrolplane` CR. The operator then applies the change itself.

---

## Why `skipIfAlreadyExists: true` on the Restore CR (same-namespace restore)?

When performing a full disaster restore to the same namespace (`openstack`), the
StatefulSet and other Kubernetes resources still exist — they are just scaled to
0 replicas. Trilio for Kubernetes would normally try to recreate them, fail with a conflict
error, and abort the restore.

`skipIfAlreadyExists: true` (under `restoreFlags`) tells T4K to skip any resource
that already exists and focus only on what is missing — in this case, the deleted
PVCs. The StatefulSet is left untouched and the PVCs are recreated from backup.

---

## Why `useOCPNamespaceUIDRange: true` for cross-namespace restores?

OpenShift assigns a unique UID range to every namespace from a cluster-wide pool.
All pods in a namespace run under a UID within that range, and files on PVCs are
owned by those UIDs.

When restoring a PVC from the `openstack` namespace into a different namespace
(e.g. `galera-restore-test`), the restored files carry the original UID from
`openstack`. The target namespace has a completely different UID range. MySQL
starts, tries to read `/var/lib/mysql`, and gets a permission denied error
because it is running under a UID that does not own the files.

`useOCPNamespaceUIDRange: true` instructs T4K to remap file ownership on the
restored PVC to match the target namespace's UID range. Without this flag, cross-
namespace restores in OpenShift will always fail at the MySQL startup stage.

---

## Why does `safe_to_bootstrap` not need manual intervention?

In earlier Galera versions (and in non-OSCP deployments), after a full cluster
shutdown the `grastate.dat` file on all nodes would contain `safe_to_bootstrap: 0`
and `seqno: -1`, indicating that no node knows it is safe to bootstrap. This
required manually editing `grastate.dat` on the most up-to-date node to set
`safe_to_bootstrap: 1` before restarting.

In RHOSO 18, the OSCP Galera operator handles this automatically. It reads the
`grastate.dat` files, determines the most up-to-date node, and orchestrates the
bootstrap sequence without manual intervention. This was confirmed in live testing
(Test 4).

---

## Why does the Backup Target type (NFS vs S3) not affect the procedures?

Trilio for Kubernetes abstracts the backup storage behind a `Target` CR. The backup,
restore, and hook procedures are identical regardless of whether the target is
NFS or S3-compatible object storage. The only difference is the Target CR
definition itself (credentials, endpoint, bucket/share name).

All procedures in this repository apply to both target types. Where "NFS" is
mentioned in observed results or timing notes, it refers specifically to the
lab environment used for testing, not to a requirement.

---

**Version:** 1.0
**Created:** February 19, 2026
**Purpose:** Design rationale — explains the *why* behind each decision
