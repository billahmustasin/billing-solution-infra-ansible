#!/usr/bin/env bash
# Test root SSH key auth from Jenkins to every inventory host (no Ansible required).
set -euo pipefail

KEY="${HOME}/.ssh/id_ed25519_ansible"
PORT=65297
USER=root
SSH_OPTS=(-p "${PORT}" -i "${KEY}" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

HOSTS=(
  172.17.106.2:db-a1a
  172.17.106.3:db-a1b
  172.17.106.4:db-a2a
  172.17.106.5:db-a2b
  172.17.106.6:etcd-witness
  172.17.105.7:redis-a1
  172.17.105.8:redis-a2
  172.17.105.9:kafka-a1
  172.17.105.10:kafka-a2
  172.17.105.11:k8s-master-1
  172.17.105.12:k8s-worker-1
  172.17.105.13:k8s-worker-2
  172.17.105.16:jenkins-a1
  172.17.105.17:harbor-a1
  172.17.106.7:minio-a1
  172.17.106.8:nfs-a1
)

if [[ ! -f "${KEY}" ]]; then
  echo "Missing ${KEY} — run: bash scripts/setup-ansible-ssh-key.sh"
  exit 1
fi

OK=0
FAIL=0
for entry in "${HOSTS[@]}"; do
  ip="${entry%%:*}"
  name="${entry##*:}"
  if ssh "${SSH_OPTS[@]}" "${USER}@${ip}" 'hostname' &>/dev/null; then
    echo "OK   ${name} (${ip})"
    ((OK++)) || true
  else
    echo "FAIL ${name} (${ip}) — key not in root@authorized_keys?"
    ((FAIL++)) || true
  fi
done

echo
echo "${OK} OK, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
