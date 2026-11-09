#!/usr/bin/env bash
# Optional collections for Ansible control node (Jenkins).
# postgres-managed.yml uses psql commands — no collections required for DB provisioning.
set -euo pipefail
cd "$(dirname "$0")/.."
ansible-galaxy collection install -r requirements.yml
echo "Collections installed."
