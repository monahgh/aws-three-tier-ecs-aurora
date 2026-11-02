#!/bin/sh
# pgbench load through RDS Proxy. Runs in the loadgen ECS task (postgres:17-alpine image).
# Connection settings come from PGHOST/PGUSER/PGPASSWORD/PGDATABASE/PGSSLMODE env vars.
# PGBENCH_EXTRA_FLAGS="-M prepared" uses named prepared statements, which can pin proxy sessions.
set -u

echo "target=$PGHOST db=$PGDATABASE clients=$PGBENCH_CLIENTS rate=$PGBENCH_RATE extra='$PGBENCH_EXTRA_FLAGS'"

until psql -XAtc "SELECT 1" >/dev/null 2>&1; do
  echo "waiting for the database..."
  sleep 5
done

if [ "$(psql -XAtc "SELECT to_regclass('public.pgbench_accounts') IS NOT NULL")" != "t" ]; then
  echo "seeding pgbench tables (scale $PGBENCH_SCALE)"
  pgbench -i -s "$PGBENCH_SCALE" || echo "seed failed; it will be retried on the next task start"
fi

while true; do
  # shellcheck disable=SC2086  # extra flags are intentionally word-split
  pgbench -n -c "$PGBENCH_CLIENTS" -j 2 -R "$PGBENCH_RATE" -T 300 -P 30 $PGBENCH_EXTRA_FLAGS ||
    echo "pgbench exited with $?, restarting"
  sleep 5
done
