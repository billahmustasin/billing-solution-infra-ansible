#!/usr/bin/env bash
# Run on Jenkins (172.17.105.16) as devopsadmin — installs Ansible SSH key to all production hosts.
set -euo pipefail

KEY="${HOME}/.ssh/id_ed25519_ansible"
PORT=65297
USER=root

HOSTS=(
  172.17.106.2  172.17.106.3  172.17.106.4  172.17.106.5  172.17.106.6
  172.17.105.7  172.17.105.8  172.17.105.9  172.17.105.10
  172.17.105.11 172.17.105.12 172.17.105.13
  172.17.105.16 172.17.105.17
  172.17.106.7  172.17.106.8
)

if [[ ! -f "${KEY}" ]]; then
  echo "Generating ${KEY} ..."
  ssh-keygen -t ed25519 -f "${KEY}" -N "" -C "ansible@jenkins-prod"
fi
chmod 600 "${KEY}"
chmod 644 "${KEY}.pub"

FAILED=()
for ip in "${HOSTS[@]}"; do
  echo "=== ${USER}@${ip}:${PORT} ==="
  if ssh-copy-id -i "${KEY}.pub" -p "${PORT}" -o StrictHostKeyChecking=accept-new "${USER}@${ip}"; then
    echo "OK"
  else
    echo "FAILED — try manually (password for root once):"
    echo "  ssh-copy-id -i ${KEY}.pub -p ${PORT} ${USER}@${ip}"
    echo "Or via devopsadmin + sudo if root password login is disabled:"
    echo "  cat ${KEY}.pub | ssh -p ${PORT} devopsadmin@${ip} 'sudo tee -a /root/.ssh/authorized_keys && sudo chmod 600 /root/.ssh/authorized_keys'"
    FAILED+=("${ip}")
  fi
done

echo
if ((${#FAILED[@]} == 0)); then
  echo "All hosts OK. Test with: bash scripts/verify-ansible-ssh.sh"
else
  echo "Failed hosts: ${FAILED[*]}"
  echo "Re-run this script after fixing, or use verify script to check remaining hosts."
  exit 1
fi
