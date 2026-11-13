# Simple Galera hook: staging test guide

For `galera-backup-hook-simple.yaml`. Run everything in **staging only**. Five
tests, in this order. Each one says what to do, what you must see, and what to
send back. If a test does not show what it says here, **stop and send the
output**: do not continue to the next one.

## What changed and why these tests

The hook no longer runs `SET GLOBAL wsrep_desync = ON`. It only opens one MySQL
session with `FLUSH TABLES WITH READ LOCK` and keeps it open. The whole design
rests on one behaviour of MariaDB Galera: **the lock by itself desyncs the node,
and releasing the lock resyncs it**. Test 0 proves that by hand, without T4K and
without the hook. If Test 0 fails, the hook is not valid and nothing else matters.

## Setup

The tests need **two terminal windows** open at the same time, both logged in
to the staging cluster with `oc`. The guide calls them terminal 1 and terminal 2:
in one you take the lock or trigger the backup, in the other you watch what
happens. A third one runs the write load.

On macOS type `bash` first in each window: every command here assumes bash, not zsh.

The block below defines a few variables and helper commands (`sql`, `st`,
`hooklog`, `pods`). They only exist in the window where you paste them, so
**paste the whole block in terminal 1 and again in terminal 2** before you
start. If you open a new window later, paste it there too. If you ever get
`command not found` for `st`, `sql`, `hooklog` or `pods`, this is why.

```bash
NS=openstack
DB=openstack-keystone

# Run one mysql command as root inside a Galera pod: sql <pod> <mysql options>
sql() {
  local pod=$1; shift
  oc -n $NS exec "$pod" -c galera -- bash -c '[ -f /var/lib/operator-scripts/mysql_root_auth.sh ] && source /var/lib/operator-scripts/mysql_root_auth.sh >/dev/null 2>&1; export MYSQL_PWD="${MYSQL_PWD:-$DB_ROOT_PASSWORD}"; exec mysql -u root "$@"' _ "$@"
}

# Galera state of one pod: st <pod>
st() {
  sql "$1" -sN -e "SHOW STATUS WHERE Variable_name IN ('wsrep_local_state_comment','wsrep_cluster_size','wsrep_local_recv_queue','wsrep_flow_control_paused');"
}

# Hook and Galera messages of one pod for the last N minutes: hooklog <pod> [N]
hooklog() {
  oc -n $NS logs "$1" -c galera --since=${2:-10}m | grep -E "trilio-backup|WSREP: (Desync|Resum|pause|resume|Provider|Member|Shifting)"
}

# Work out which pod is active and which one the hook will lock.
pods() {
  ACTIVE=$(oc -n $NS get svc $DB -o jsonpath='{.spec.selector.statefulset\.kubernetes\.io/pod-name}')
  LOCKED=""
  if [ -z "$ACTIVE" ]; then echo "STOP: cannot read the active pod. Do not continue."; return 1; fi
  for i in 2 1 0; do if [ "$DB-galera-$i" != "$ACTIVE" ]; then LOCKED=$DB-galera-$i; break; fi; done
  echo "ACTIVE (never lock this one) = $ACTIVE"
  echo "LOCKED (the hook will lock)  = $LOCKED"
}
```

## Before each test: three steps

Do these three things at the start of every test (0, 1, 2, 3 and 4).

**Step 1. Start the write load** in a third terminal and leave it running for
the whole test. Use your script that creates and deletes projects and users,
and start **5 copies of it at the same time**, not one. One copy is very little
traffic compared to production.

**Step 2. Find out which pod is which.** In terminal 1 **and** in terminal 2, type:

```bash
pods
```

It prints two lines, for example:

```
ACTIVE (never lock this one) = openstack-keystone-galera-0
LOCKED (the hook will lock)  = openstack-keystone-galera-2
```

- `ACTIVE` is the pod that is serving OpenStack right now. Nothing in this
  guide should ever lock it.
- `LOCKED` is the passive pod that the tests (and the hook) will lock.

The command also saves those two names as `$ACTIVE` and `$LOCKED`, and every
command in this guide uses them. That is why you run it in both terminals: both
must print the same two names. The names can change from one test to the next
(tests 2 and 4 move the active pod), so run it again every time.

If it prints `STOP: cannot read the active pod`, do not continue. Send me that.

**Step 3. Check the cluster is healthy.** In either terminal:

```bash
st $LOCKED
```

It prints four lines. Two of them must be exactly:

```
wsrep_local_state_comment   Synced
wsrep_cluster_size          3
```

If it says anything else, do not start the test. Send me the output.

---

## Test 0 — The lock alone desyncs and resyncs (by hand, no T4K)

Three parts, about a minute each. Run `pods` first.

### 0a. The lock ends by itself

Terminal 1. Take the lock for 30 seconds on the passive pod and let it end alone:

```bash
sql $LOCKED -e "FLUSH TABLES WITH READ LOCK; SELECT SLEEP(30);"
```

Terminal 2, during those 30 seconds:

```bash
st $LOCKED
st $ACTIVE
```

Then wait until terminal 1 returns, wait 30 seconds more, and:

```bash
st $LOCKED
hooklog $LOCKED 3
```

**Must see**
- During the lock, `st $LOCKED` shows `Donor/Desynced`.
- During the lock, `st $ACTIVE` shows `Synced` and `wsrep_flow_control_paused` close to 0.
- The write script never stops and never errors.
- After the lock, `st $LOCKED` shows `Synced` and `wsrep_cluster_size 3`, with nobody touching anything.
- In `hooklog`: `Desyncing and pausing the provider`, and about 30 seconds later `Resuming and resyncing the provider`.

### 0b. The lock is released by KILL

Terminal 1. Take the lock for 5 minutes:

```bash
sql $LOCKED -e "FLUSH TABLES WITH READ LOCK; SELECT SLEEP(300);"
```

Terminal 2. Check it is locked, find the session, kill it on the server:

```bash
st $LOCKED
sql $LOCKED -sN -e "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE 'SELECT SLEEP(300)%';"
```

It prints one number. Put it in place of `NUMBER`:

```bash
sql $LOCKED -e "KILL NUMBER;"
st $LOCKED
```

**Must see**
- Terminal 1 ends with an error ("Lost connection" or "Query execution was interrupted") at the moment of the KILL.
- `st $LOCKED` is back to `Synced` within seconds, not after 5 minutes.

### 0c. The locked pod is restarted

Terminal 1, take the lock again exactly as in 0b. Terminal 2:

```bash
oc -n $NS delete pod $LOCKED
oc -n $NS get pods -l cr=galera-$DB -w
```

Wait until the pod is Running and Ready again, press Ctrl-C, then:

```bash
st $LOCKED
oc -n $NS logs $LOCKED -c galera | grep -E "WSREP.*(IST|SST|State transfer)"
```

**Must see**
- The pod comes back, `Synced`, cluster size 3.
- Tell me whether the log shows IST (incremental, expected) or SST (full copy).

**Send back for Test 0:** every `st` output of 0a, 0b and 0c, the last `grep`, and `hooklog $LOCKED 15`.

---

## Apply the hook (before Test 1)

```bash
git pull
oc apply -f galera-backup-hook-simple.yaml
oc -n $NS get hook galera-backup-hook -o yaml | grep -c LOCK_MAX_SECONDS
```

The last command must print a number **above 0**. If it prints 0, the old hook
is still in the cluster.

Use your Keystone test BackupPlan: the one that selects the three Keystone PVCs
and runs `galera-backup-hook` on the Keystone Galera pods. The plan does not change.

---

## Test 1 — Normal backup with write load

1. Run `pods`. Write load running (5 copies).
2. Terminal 2: `oc -n $NS get endpoints $DB -w`
3. Trigger one backup of the Keystone plan and wait until it finishes.
4. Then:

```bash
for i in 0 1 2; do echo "== $DB-galera-$i"; hooklog $DB-galera-$i; st $DB-galera-$i; done
```

**Must see**
- On the `LOCKED` pod: `PRE-BACKUP HOOK OK`, then `Lock was held for the whole snapshot`, then `POST-BACKUP HOOK OK`.
- On the other two pods: a line ending in `Skipping.`, then `This pod was not quiesced`.
- The endpoints watch never loses the active pod's IP.
- The write script never errors.
- Backup status `Available`. All three pods `Synced` at the end.

**Send back:** the output of step 4 and the backup status.

---

## Test 2 — Traffic lands on the locked pod (watchdog)

This forces the bad case: the Service points at the pod we have locked. The
watchdog must release it within seconds.

1. Run `pods`. Write load running. Make sure the last backup finished more than a minute ago.
2. Terminal 2: paste this and press Enter **before** you trigger the backup. It
   waits by itself for the lock, then points the Service at the locked pod:

```bash
[ -n "$LOCKED" ] && until oc -n $NS logs $LOCKED -c galera --since=30s | grep -q "PRE-BACKUP HOOK OK"; do sleep 1; done; date; oc -n $NS patch svc $DB --type=merge -p '{"spec":{"selector":{"statefulset.kubernetes.io/pod-name":"'$LOCKED'"}}}'
```

3. Terminal 1: trigger the backup. Wait until it finishes.
4. Then:

```bash
hooklog $LOCKED
st $LOCKED
```

5. Leave the Service where it is (the locked pod is now the active one, and it
   is healthy). Run `pods` again: the names have changed.

**Must see**
- Within about 10 seconds of the time printed by `date`: `WATCHDOG: Service points at this pod while locked. Killing the lock session.`
- Then, from the post-hook: `the lock session was NOT alive at post-hook time`.
- Backup status **Failed**. That is the correct result.
- `st` shows `Synced`.
- The write script pauses or errors for a few seconds, not more.

**If instead you see** `Lock was held for the whole snapshot` and no `WATCHDOG`
line: the snapshot finished before the watchdog's first check. The test is
inconclusive, not failed. Repeat it.

**Send back:** `hooklog`, the time printed by `date`, how long the write script
was blocked, and the backup status.

---

## Test 3 — The lock cannot be taken

A session holding a table write lock makes the global lock wait. We use a
system table that nothing writes to, so the cluster is not affected.

1. Run `pods`.
2. **Check first that the blocker really blocks.** Terminal 2, start it (it runs 100 seconds):

```bash
sql $LOCKED -e "LOCK TABLES mysql.help_topic WRITE; SELECT SLEEP(100);"
```

   Terminal 1, while it runs:

```bash
sql $LOCKED -e "SET SESSION lock_wait_timeout = 5; FLUSH TABLES WITH READ LOCK;"
```

   This must fail after about 5 seconds with `ERROR 1205 ... Lock wait timeout exceeded`.
   **If it does not fail, skip Test 3 and tell me**: I need a different blocker.
   Wait until the blocker in terminal 2 ends.

3. Now the real test. Terminal 2, start the blocker again (same command as in step 2).
4. Within 10 seconds, trigger the backup in terminal 1. Wait until it finishes.

```bash
hooklog $LOCKED
st $LOCKED
```

5. Wait until the blocker ends, then trigger **one more backup** with nothing blocking.

**Must see**
- First backup: `Lock session started, waiting for FTWRL...` and, 60 to 70 seconds later, `Lock not confirmed ... Released, aborting.` Backup status **Failed**. `st` shows `Synced`.
- Second backup: normal, exactly as Test 1, with **no cleanup by hand** in between.

**Send back:** the result of step 2, `hooklog $LOCKED 20` covering both backups, and both backup statuses.

---

## Test 4 — The active pod dies during the backup (real failover)

Same idea as Test 2, with a real failure instead of a patch.

1. Run `pods`. Write load running. Last backup finished more than a minute ago.
2. Terminal 2: paste and press Enter **before** you trigger the backup:

```bash
[ -n "$ACTIVE" ] && until oc -n $NS logs $LOCKED -c galera --since=30s | grep -q "PRE-BACKUP HOOK OK"; do sleep 1; done; date; oc -n $NS delete pod $ACTIVE
```

3. Terminal 1: trigger the backup. Wait until the backup finishes and the
   deleted pod is Running again.
4. Then:

```bash
pods
for i in 0 1 2; do echo "== $DB-galera-$i"; hooklog $DB-galera-$i; st $DB-galera-$i; done
```

**Must see**
- The database is writable again within about 60 seconds of the time printed by `date`, whichever pod became active.
- If the pod that was locked became the active one: a `WATCHDOG` line (either `Service points at this pod while locked` or `active pod unknown for 30 s`), then `the lock session was NOT alive at post-hook time`, and the backup **Failed**.
- If the other pod became active: no `WATCHDOG` line. Tell me the backup status.
- At the end: three pods `Synced`, cluster size 3.

**Send back:** which pod became active, how long the write script was blocked,
the output of step 4, and the backup status.

---

## What I need at the end

One file with, for each test, the output listed under "Send back" and one line
saying whether the "Must see" list was met. And the operator version of staging
and of production:

```bash
oc get csv -n openstack-operators | grep mariadb
```

## If something looks odd

- `command not found` for `st`, `sql`, `hooklog` or `pods`: paste the Setup block again in that terminal.
- `hooklog` shows lines with `trilio-backup` but none with `WSREP:`: the Galera
  log is going to a file and not to the pod log. Tell me and I will send another command.
- Anything that does not match a "Must see" list: stop and send me the output.
