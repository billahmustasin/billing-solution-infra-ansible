#!/usr/bin/env bash
# Provision production databases on both Patroni clusters.
# Run on Jenkins (172.17.105.16) from myrace-ansible-playbooks directory.
#
# Secrets: set APP_DB_PASSWORD (same as group_vars/*/vault.yml app_db_password).
# Service-role SQL is rendered from vault via ansible-playbook (no plaintext in git).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KEY="${HOME}/.ssh/id_ed25519_ansible"
PORT=65297
APP_USER=production_db_user
APP_PASS="${APP_DB_PASSWORD:?Set APP_DB_PASSWORD (same as group_vars/*/vault.yml app_db_password)}"

run_sql() {
  local host=$1
  local sql_file=$2
  echo "=== Running ${sql_file} on ${host} ==="
  scp -P "${PORT}" -i "${KEY}" -o StrictHostKeyChecking=accept-new \
    "${SCRIPT_DIR}/sql/${sql_file}" "root@${host}:/tmp/${sql_file}"
  ssh -p "${PORT}" -i "${KEY}" -o StrictHostKeyChecking=accept-new "root@${host}" \
    "su - postgres -c 'psql -v ON_ERROR_STOP=1 -f /tmp/${sql_file}'"
}

add_pgbouncer_user() {
  local host=$1
  echo "=== PgBouncer ${host} ==="
  ssh -p "${PORT}" -i "${KEY}" -o StrictHostKeyChecking=accept-new "root@${host}" bash -s <<EOF
grep -q '${APP_USER}' /etc/pgbouncer/userlist.txt 2>/dev/null || \
  echo '"${APP_USER}" "${APP_PASS}"' >> /etc/pgbouncer/userlist.txt
systemctl restart pgbouncer
grep '${APP_USER}' /etc/pgbouncer/userlist.txt
EOF
}

cd "${ROOT_DIR}"

# Cluster 1 leader — create DBs if SQL present
if [[ -f "${SCRIPT_DIR}/sql/cluster1-databases.sql" ]]; then
  run_sql 172.17.106.2 cluster1-databases.sql
fi
# Cluster 2 leader
if [[ -f "${SCRIPT_DIR}/sql/cluster2-databases.sql" ]]; then
  run_sql 172.17.106.4 cluster2-databases.sql
fi

# Per-service roles (passwords from group_vars/*/vault.yml)
ansible-playbook postgres-service-db-roles.yml

for ip in 172.17.106.2 172.17.106.3 172.17.106.4 172.17.106.5; do
  add_pgbouncer_user "${ip}"
done

echo ""
echo "Done. Verify:"
echo "  psql -h 172.17.106.200 -p 5000 -U production_db_user -d race_core_service -c '\\dn'"
echo "  psql -h 172.17.106.201 -p 5000 -U production_db_user -d race_core_service -c '\\dn'"
