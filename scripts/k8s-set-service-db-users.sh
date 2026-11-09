#!/usr/bin/env bash
# Point production workloads at per-service DB roles (Phase 1).
# Patches Helm secrets (secret env overrides ConfigMap) and rolling-restarts.
# Does not change DR. Password stays MYRACE_PROD_DATABASE_PASSWORD.
set -euo pipefail

NS="${NS:-myrace-production}"
CONTEXT="${CONTEXT:-}"
KUBECTL=(sudo -u jenkins kubectl)
if [[ -n "${CONTEXT}" ]]; then
  KUBECTL+=(--context "${CONTEXT}")
fi

# helm release name → Postgres role
declare -A USERS=(
  [myrace-core-billingsrv]=race_billing_srv_user
  [myrace-core-entitysrv]=race_entity_srv_user
  [myrace-core-metasrv]=race_meta_srv_user
  [myrace-core-invoicesrv]=race_invoice_srv_user
  [myrace-core-reportsrv]=race_report_srv_user
  [myrace-core-appadminsrv]=race_appadmin_srv_user
  [myrace-master-billing]=race_billing_user
  [myrace-partner]=race_partner_user
  [myrace-core-customersrv]=race_customer_srv_user
  [myrace-core-financesrv]=race_finance_srv_user
  [myrace-core-notificationsrv]=race_notification_srv_user
  [myrace-core-schedulersrv]=race_scheduler_srv_user
  [myrace-core-loyaltycampaignsrv]=race_loyalty_campaign_srv_user
  [myrace-superapp]=race_superapp_user
  [myrace-customer-chat]=race_customer_chat_user
)

patch_one() {
  local release="$1"
  local user="$2"
  local secret="${release}-secret"
  local deploy="${release}-deployment"

  if ! "${KUBECTL[@]}" -n "${NS}" get secret "${secret}" >/dev/null 2>&1; then
    echo "SKIP ${release}: secret ${secret} not found"
    return 0
  fi

  echo "=== ${release} → ${user} ==="
  "${KUBECTL[@]}" -n "${NS}" patch secret "${secret}" --type merge -p \
    "{\"stringData\":{\"DATABASE_USERNAME\":\"${user}\"}}"

  if "${KUBECTL[@]}" -n "${NS}" get deploy "${deploy}" >/dev/null 2>&1; then
    "${KUBECTL[@]}" -n "${NS}" rollout restart "deployment/${deploy}"
    "${KUBECTL[@]}" -n "${NS}" rollout status "deployment/${deploy}" --timeout=10m
  else
    echo "SKIP rollout: ${deploy} not found"
  fi
}

for release in "${!USERS[@]}"; do
  patch_one "${release}" "${USERS[$release]}"
done

echo
echo "Done. Next Jenkins helm deploy will overwrite DATABASE_USERNAME unless"
echo "the job stops injecting MYRACE_PROD_DATABASE_USERNAME (shared) or the"
echo "helm wrapper forces the mapped user as the last --set-string."
