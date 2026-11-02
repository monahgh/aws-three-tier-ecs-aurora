#!/usr/bin/env bash
# Aurora failover test. Probes the target twice a second (new connection each time:
# SELECT inet_server_addr(), pg_is_in_recovery(), then an INSERT), triggers
# `aws rds failover-db-cluster`, and reports write unavailability and stale-DNS hits.
#
#   TARGET=cluster bash /opt/dblab/scripts/failover_test.sh   # via the cluster writer endpoint (DNS)
#   TARGET=proxy   bash /opt/dblab/scripts/failover_test.sh   # via RDS Proxy
#
# Probe states:
#   OK     write succeeded
#   DOWN   could not connect (or timed out)
#   STALE  connected through the writer name but landed on a reader (stale DNS after failover)
#   ERR    connected to a writer but the write failed
set -euo pipefail
. /etc/profile.d/dblab.sh

TARGET="${TARGET:-cluster}"
case "$TARGET" in
  cluster) use_writer >/dev/null ;;
  proxy)   use_proxy >/dev/null ;;
  *) echo "TARGET must be 'cluster' or 'proxy'"; exit 1 ;;
esac

AWS="aws --region $DBLAB_REGION"
LOG=$(mktemp "/tmp/failover_${TARGET}.XXXXXX")
export PGCONNECT_TIMEOUT=2

writer_instance() {
  $AWS rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" \
    --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter].DBInstanceIdentifier' --output text
}

psql -XqAt -v ON_ERROR_STOP=1 -c "CREATE TABLE IF NOT EXISTS failover_probe (id bigserial PRIMARY KEY, written_at timestamptz NOT NULL DEFAULT clock_timestamp());"
BEFORE=$(writer_instance)
echo "Target: $TARGET ($PGHOST)"
echo "Writer before: $BEFORE"

probe() {
  while true; do
    ts=$(date +%s.%N)
    rc=0
    out=$(timeout 3 psql -XqAt -F ' ' -v ON_ERROR_STOP=1 \
      -c "SELECT inet_server_addr(), pg_is_in_recovery()" \
      -c "INSERT INTO failover_probe DEFAULT VALUES" 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ]; then
      state=OK
    elif [ -z "$out" ]; then
      state=DOWN
    elif [ "${out##* }" = "t" ]; then
      state=STALE
    else
      state=ERR
    fi
    echo "$ts $state ${out:-}"
    sleep 0.5
  done
}

probe >"$LOG" &
PROBE_PID=$!
trap 'kill $PROBE_PID 2>/dev/null || true' EXIT

sleep 10
echo "[$(date -u +%T)] Triggering failover of $CLUSTER_ID"
$AWS rds failover-db-cluster --db-cluster-identifier "$CLUSTER_ID" >/dev/null

AFTER="$BEFORE"
for _ in $(seq 1 60); do
  sleep 5
  AFTER=$(writer_instance)
  if [ -n "$AFTER" ] && [ "$AFTER" != "$BEFORE" ]; then break; fi
done
echo "[$(date -u +%T)] Writer is now: $AFTER"
$AWS rds wait db-cluster-available --db-cluster-identifier "$CLUSTER_ID"
echo "[$(date -u +%T)] Cluster available, probing 30 more seconds"
sleep 30
kill $PROBE_PID 2>/dev/null || true

echo
echo "Probe log: $LOG"
awk -v target="$TARGET" '
  { n[$2]++ }
  $2 != "OK" { if (!first_bad) first_bad = $1; need_recover = 1 }
  $2 == "OK" { if (!ip_before) ip_before = $3; ip_after = $3
               if (need_recover) { recovered = $1; need_recover = 0 } }
  END {
    printf "Target: %s\n", target
    printf "Probes: OK=%d DOWN=%d STALE=%d ERR=%d\n", n["OK"], n["DOWN"], n["STALE"], n["ERR"]
    if (!first_bad)        print "No failed writes observed."
    else if (need_recover) print "Writes had not recovered when probing stopped."
    else printf "Write unavailability: %.1f s (first failed write -> first successful write after the last failure)\n", recovered - first_bad
    printf "Stale-DNS hits (connected to a reader via the writer name): %d\n", n["STALE"]
    printf "Server IP before: %s  after: %s\n", ip_before, ip_after
  }' "$LOG"
