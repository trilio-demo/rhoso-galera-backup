#!/bin/bash
# =============================================================================
# Galera & OpenStack Health Check - Read-Only, Non-Destructive
# =============================================================================

NS="openstack"
PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✔${NC} $*"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✘${NC} $*"; FAIL=$((FAIL+1)); }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# =============================================================================
# 1. GALERA CLUSTER HEALTH
# =============================================================================
header "1. Galera Cluster Health"

for i in 0 1 2; do
    echo ""
    echo "  --- galera-$i ---"
    if ! oc get pod "openstack-galera-$i" -n "$NS" &>/dev/null; then
        fail "galera-$i: pod does not exist"
        continue
    fi

    output=$(oc exec "openstack-galera-$i" -n "$NS" -c galera -- bash -c \
        'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
          SHOW STATUS LIKE \"wsrep_cluster_size\";
          SHOW STATUS LIKE \"wsrep_local_state_comment\";
          SHOW STATUS LIKE \"wsrep_cluster_status\";
          SHOW VARIABLES LIKE \"wsrep_desync\";"' 2>/dev/null) || true

    if [[ -z "$output" ]]; then
        fail "galera-$i: not responding"
        continue
    fi

    echo "$output" | sed 's/^/    /'

    cluster_size=$(echo "$output" | awk '/wsrep_cluster_size/{print $2}')
    state=$(echo "$output" | awk '/wsrep_local_state_comment/{print $2}')
    status=$(echo "$output" | awk '/wsrep_cluster_status/{print $2}')
    desync=$(echo "$output" | awk '/wsrep_desync/{print $2}')

    [[ "$cluster_size" == "3" ]]  && pass "galera-$i: cluster_size=3" || fail "galera-$i: cluster_size=$cluster_size (expected 3)"
    [[ "$state" == "Synced" ]]    && pass "galera-$i: state=Synced"   || fail "galera-$i: state=$state (expected Synced)"
    [[ "$status" == "Primary" ]]  && pass "galera-$i: status=Primary" || fail "galera-$i: status=$status (expected Primary)"
    [[ "$desync" == "OFF" ]]      && pass "galera-$i: desync=OFF"     || fail "galera-$i: desync=$desync (expected OFF)"
done

# =============================================================================
# 2. GALERA RESOURCES
# =============================================================================
header "2. Galera Kubernetes Resources"

oc get statefulset openstack-galera -n "$NS" &>/dev/null \
    && pass "StatefulSet openstack-galera" || fail "StatefulSet openstack-galera MISSING"

for i in 0 1 2; do
    oc get pvc "mysql-db-openstack-galera-$i" -n "$NS" &>/dev/null \
        && pass "PVC mysql-db-openstack-galera-$i" \
        || fail "PVC mysql-db-openstack-galera-$i MISSING"
done

oc get secret osp-secret -n "$NS" &>/dev/null \
    && pass "Secret osp-secret" || fail "Secret osp-secret MISSING"
oc get secret combined-ca-bundle -n "$NS" &>/dev/null \
    && pass "Secret combined-ca-bundle" || fail "Secret combined-ca-bundle MISSING"
oc get svc openstack-galera -n "$NS" &>/dev/null \
    && pass "Service openstack-galera" || fail "Service openstack-galera MISSING"
oc get sa galera-openstack -n "$NS" &>/dev/null \
    && pass "ServiceAccount galera-openstack" || fail "ServiceAccount galera-openstack MISSING"
oc get cm openstack-config-data -n "$NS" &>/dev/null \
    && pass "ConfigMap openstack-config-data" || fail "ConfigMap openstack-config-data MISSING"

# =============================================================================
# 3. DATABASES
# =============================================================================
header "3. Databases"

echo ""
db_output=$(oc exec openstack-galera-0 -n "$NS" -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -sN -e "
      SELECT table_schema, COUNT(*) as table_count
      FROM information_schema.tables
      WHERE table_schema NOT IN (\"information_schema\",\"performance_schema\",\"mysql\",\"sys\")
      GROUP BY table_schema ORDER BY table_schema;"' 2>/dev/null) || true

if [[ -z "$db_output" ]]; then
    fail "Could not query databases"
else
    echo "$db_output" | column -t | sed 's/^/  /'
    echo ""
    for db in barbican cinder dmapi glance keystone neutron nova_api nova_cell0 placement workloadmgr; do
        echo "$db_output" | grep -q "^$db" \
            && pass "$db present" || fail "$db MISSING"
    done
fi

# =============================================================================
# 4. WRITE + REPLICATION (creates and immediately drops a temp DB)
# =============================================================================
header "4. Write + Replication"

tmp_db="healthcheck_$(date +%s)"

if oc exec openstack-galera-0 -n "$NS" -c galera -- bash -c \
    "mysql -u root -p\"\${DB_ROOT_PASSWORD}\" -e \"
      CREATE DATABASE ${tmp_db};
      USE ${tmp_db};
      CREATE TABLE t (id INT);
      INSERT INTO t VALUES (1);\"" 2>/dev/null; then

    for i in 1 2; do
        val=$(oc exec "openstack-galera-$i" -n "$NS" -c galera -- bash -c \
            "mysql -u root -p\"\${DB_ROOT_PASSWORD}\" -sN -e \
              \"SELECT id FROM ${tmp_db}.t;\"" 2>/dev/null || echo "")
        [[ "$val" == "1" ]] \
            && pass "Replication to galera-$i" \
            || fail "Replication to galera-$i (got: '$val')"
    done

    oc exec openstack-galera-0 -n "$NS" -c galera -- bash -c \
        "mysql -u root -p\"\${DB_ROOT_PASSWORD}\" -e \"DROP DATABASE ${tmp_db};\"" 2>/dev/null
else
    fail "Could not write to galera-0"
fi

# =============================================================================
# 5. SERVICE ENDPOINT
# =============================================================================
header "5. Galera Service Endpoint"

oc exec openstack-galera-0 -n "$NS" -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -h openstack-galera -e "SELECT 1;" &>/dev/null' \
    && pass "Service DNS openstack-galera resolves and connects" \
    || fail "Cannot connect via service endpoint openstack-galera"

# =============================================================================
# 6. OPENSTACK PODS
# =============================================================================
header "6. OpenStack Pods"

unhealthy=$(oc get pods -n "$NS" --no-headers 2>/dev/null | grep -v -E "Running|Completed" || true)
if [[ -z "$unhealthy" ]]; then
    pass "All pods in Running/Completed state"
else
    count=$(echo "$unhealthy" | wc -l)
    fail "$count pod(s) NOT in Running/Completed state:"
    echo "$unhealthy" | awk '{print "    "$1, $3}'
fi

restarted=$(oc get pods -n "$NS" --no-headers 2>/dev/null | awk '$4 > 5 {print}' || true)
if [[ -z "$restarted" ]]; then
    pass "No pods with excessive restarts (>5)"
else
    warn "Pods with >5 restarts (may indicate DB reconnection issues):"
    echo "$restarted" | awk '{print "    "$1, "restarts:", $4}'
fi

# =============================================================================
# 7. OPENSTACK SERVICE APIs
# =============================================================================
header "7. OpenStack Service APIs"

CLIENT_POD=$(oc get pod -n "$NS" -l service=openstackclient \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
    oc get pod -n "$NS" --no-headers 2>/dev/null | grep openstackclient | head -1 | awk '{print $1}')

if [[ -z "$CLIENT_POD" ]]; then
    warn "No openstackclient pod found - skipping API checks"
else
    echo "  Using: $CLIENT_POD"
    echo ""

    check_api() {
        local name="$1"; shift
        if oc exec "$CLIENT_POD" -n "$NS" -- bash -c "$*" &>/dev/null; then
            pass "$name"
        else
            fail "$name"
        fi
    }

    check_api "Keystone"  "openstack token issue -f value -c id"
    check_api "Nova"      "openstack server list --limit 1"
    check_api "Neutron"   "openstack network list"
    check_api "Glance"    "openstack image list --limit 1"
    check_api "Cinder"    "openstack volume list --limit 1"
    check_api "Placement" "openstack resource provider list"
    check_api "Barbican"  "openstack secret list --limit 1"
fi

# =============================================================================
# 8. KEY TABLE ROW COUNTS
# =============================================================================
header "8. Key Table Row Counts"

echo ""
oc exec openstack-galera-0 -n "$NS" -c galera -- bash -c \
    'mysql -u root -p"${DB_ROOT_PASSWORD}" -e "
      SELECT \"keystone.project\"    as \`table\`, COUNT(*) as cnt FROM keystone.project
      UNION ALL
      SELECT \"neutron.networks\",              COUNT(*) FROM neutron.networks
      UNION ALL
      SELECT \"nova_api.flavors\",              COUNT(*) FROM nova_api.flavors
      UNION ALL
      SELECT \"glance.images\",                 COUNT(*) FROM glance.images
      UNION ALL
      SELECT \"cinder.volumes\",                COUNT(*) FROM cinder.volumes
      UNION ALL
      SELECT \"placement.resource_providers\",  COUNT(*) FROM placement.resource_providers;"' \
    2>/dev/null | sed 's/^/  /' \
    && pass "Key table queries succeeded" \
    || fail "Key table queries failed"

# =============================================================================
# SUMMARY
# =============================================================================
header "Summary"
echo ""
echo -e "  ${GREEN}Passed: $PASS${NC}"
echo -e "  ${RED}Failed: $FAIL${NC}"
echo "  Date:   $(date)"
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}✔ ALL CHECKS PASSED${NC}"
else
    echo -e "  ${RED}✘ $FAIL CHECK(S) FAILED - review output above${NC}"
fi
echo ""
