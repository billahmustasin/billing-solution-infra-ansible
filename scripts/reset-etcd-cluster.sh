#!/usr/bin/env bash
# Wipe failed etcd bootstrap data before re-running postgres-managed.yml.
# Run from Jenkins control node after fixing group_vars/etcd_cluster.yml.
set -euo pipefail

INVENTORY="${1:-etc-ansible-hosts.txt}"

ansible etcd_cluster -i "${INVENTORY}" -b -m shell -a \
  'systemctl stop etcd 2>/dev/null || true; rm -rf /var/lib/etcd/*; systemctl reset-failed etcd 2>/dev/null || true'

echo "etcd data cleared on etcd_cluster. Re-run:"
echo "  ansible-playbook -i ${INVENTORY} postgres-managed.yml"
