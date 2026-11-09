#!/usr/bin/env bash
# Read-only snapshot of Patroni role, Postgres backends, and PgBouncer pools.
# Prints one JSON object to stdout and appends it to a daily jsonl file.
#
# Safe to run on primaries and standbys. Does not write to Postgres.
set -euo pipefail

OUT_DIR="${PG_POOL_OBSERVE_DIR:-/var/log/pg-pool-observe}"
mkdir -p "${OUT_DIR}"
chmod 750 "${OUT_DIR}"

HOST="${OBSERVE_HOSTNAME:-}"
if [ -z "${HOST}" ] || [ "${HOST}" = "localhost" ]; then
  HOST="$(tr -d ' \n' < /etc/hostname 2>/dev/null || true)"
fi
if [ -z "${HOST}" ] || [ "${HOST}" = "localhost" ]; then
  HOST="$(hostname -s 2>/dev/null || uname -n)"
fi
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DAY="$(date -u +%F)"
JSONL="${OUT_DIR}/${DAY}.jsonl"
TMP="$(mktemp)"
trap 'rm -f "${TMP}" "${TMP}.pgbouncer" "${TMP}.patroni"' EXIT

pg_sql() {
  sudo -u postgres psql -d postgres -Atqc "$1"
}

patroni_json='{}'
if curl -sf --max-time 2 http://127.0.0.1:8008/patroni >"${TMP}.patroni" 2>/dev/null; then
  patroni_json="$(cat "${TMP}.patroni")"
fi

queued_24h=0
if command -v journalctl >/dev/null 2>&1; then
  queued_24h="$(journalctl -u pgbouncer --since '24 hours ago' --no-pager 2>/dev/null | grep -c 'client being queued' || true)"
fi

# pg_stat_activity rollups as JSON (peer auth, local socket — not via PgBouncer).
pg_payload="$(pg_sql "
SELECT json_build_object(
  'max_connections', current_setting('max_connections')::int,
  'total', (SELECT count(*) FROM pg_stat_activity),
  'active', (SELECT count(*) FROM pg_stat_activity WHERE state = 'active'),
  'idle', (SELECT count(*) FROM pg_stat_activity WHERE state = 'idle'),
  'idle_in_transaction', (SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction'),
  'waiting', (SELECT count(*) FROM pg_stat_activity WHERE wait_event_type IS NOT NULL AND state = 'active'),
  'by_database', (
    SELECT COALESCE(json_agg(row_to_json(d) ORDER BY d.conns DESC), '[]'::json)
    FROM (
      SELECT datname,
             count(*) AS conns,
             count(*) FILTER (WHERE state = 'active') AS active,
             count(*) FILTER (WHERE state = 'idle') AS idle,
             count(*) FILTER (WHERE state = 'idle in transaction') AS idle_in_transaction
      FROM pg_stat_activity
      WHERE datname IS NOT NULL
      GROUP BY datname
    ) d
  ),
  'by_user_db_app', (
    SELECT COALESCE(json_agg(row_to_json(u) ORDER BY u.conns DESC), '[]'::json)
    FROM (
      SELECT COALESCE(usename, '') AS usename,
             COALESCE(datname, '') AS datname,
             COALESCE(application_name, '') AS application_name,
             count(*) AS conns,
             count(*) FILTER (WHERE state = 'active') AS active,
             count(*) FILTER (WHERE state = 'idle') AS idle
      FROM pg_stat_activity
      WHERE datname IS NOT NULL
      GROUP BY 1, 2, 3
    ) u
  ),
  'wait_events', (
    SELECT COALESCE(json_agg(row_to_json(w) ORDER BY w.conns DESC), '[]'::json)
    FROM (
      SELECT COALESCE(wait_event_type, '') AS wait_event_type,
             COALESCE(wait_event, '') AS wait_event,
             count(*) AS conns
      FROM pg_stat_activity
      WHERE wait_event IS NOT NULL
      GROUP BY 1, 2
      ORDER BY count(*) DESC
      LIMIT 15
    ) w
  )
);
")"

pgbouncer_payload='{"ok": false, "error": "not captured"}'
pgb_pass="${PGBOUNCER_ADMIN_PASSWORD:-${PGPASSWORD:-}}"
if [ -n "${pgb_pass}" ]; then
  if PGPASSWORD="${pgb_pass}" psql -h 127.0.0.1 -p 6432 -U postgres -d pgbouncer -A -F$'\t' -P pager=off -c "SHOW POOLS;" >"${TMP}.pgbouncer" 2>"${TMP}.pgbouncer.err"; then
    pgbouncer_payload="$(python3 - "${TMP}.pgbouncer" <<'PY'
import json, sys
path = sys.argv[1]
rows = []
header = None
with open(path, encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line or line.startswith("(") or line == "SHOW POOLS":
            continue
        cols = line.split("\t")
        if header is None:
            header = cols
            continue
        if len(cols) != len(header):
            continue
        rec = dict(zip(header, cols))
        for k, v in list(rec.items()):
            if v.isdigit() or (v.startswith("-") and v[1:].isdigit()):
                rec[k] = int(v)
        rows.append(rec)
print(json.dumps({"ok": True, "pools": rows}))
PY
)"
  else
    err="$(tr '\n' ' ' <"${TMP}.pgbouncer.err" | head -c 400)"
    pgbouncer_payload="$(python3 -c 'import json,sys; print(json.dumps({"ok": False, "error": sys.argv[1]}))' "${err:-psql failed}")"
  fi
fi

python3 - "${HOST}" "${TS}" "${queued_24h}" "${patroni_json}" "${pg_payload}" "${pgbouncer_payload}" "${JSONL}" <<'PY'
import json, sys

host, ts, queued, patroni_raw, pg_raw, pgb_raw, jsonl = sys.argv[1:]
try:
    patroni = json.loads(patroni_raw) if patroni_raw else {}
except json.JSONDecodeError:
    patroni = {"raw": patroni_raw}
try:
    pg = json.loads(pg_raw) if pg_raw else {}
except json.JSONDecodeError:
    pg = {"error": pg_raw}
try:
    pgb = json.loads(pgb_raw) if pgb_raw else {}
except json.JSONDecodeError:
    pgb = {"ok": False, "error": pgb_raw}

role = patroni.get("role") or (patroni.get("patroni") or {}).get("role")
doc = {
    "captured_at": ts,
    "host": host,
    "patroni_role": role,
    "patroni_state": patroni.get("state"),
    "cluster": patroni.get("patroni", {}).get("scope") if isinstance(patroni.get("patroni"), dict) else patroni.get("scope"),
    "pgbouncer_queued_24h": int(queued or 0),
    "postgres": pg,
    "pgbouncer": pgb,
}
line = json.dumps(doc, separators=(",", ":"))
print(line)
with open(jsonl, "a", encoding="utf-8") as f:
    f.write(line + "\n")
PY
