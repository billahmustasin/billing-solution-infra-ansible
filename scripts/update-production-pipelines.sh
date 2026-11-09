#!/usr/bin/env bash
# Update all RACE-PRODUCTION job pipelines for production environment.
#
# Changes applied to each job XML:
#   gitBranchName  -> master
#   namespaceName  -> myrace-production
#   registryUrl    -> 172.17.105.17
#   registryCredential -> harbor_production_credential
#   k8s-uat*.yml / k8s-uat*.yaml -> k8s-production*.yml / k8s-production*.yaml
#   stage names containing [staging] / [uat] / [beta] -> [production]
#   PROFILE=uat -> PROFILE=production  (frontend Dockerfiles)
set -euo pipefail

PROD_URL="${JENKINS_PROD_URL:-https://45.114.84.54}"
PROD_USER="${JENKINS_PROD_USER:-myrace-admin}"
PROD_PASS="${JENKINS_PROD_PASS:?Set JENKINS_PROD_PASS}"

TARGET_FOLDER="RACE-PRODUCTION"

COOKIE_JAR=$(mktemp)
trap 'rm -f "${COOKIE_JAR}" /tmp/prod_job_*.xml 2>/dev/null' EXIT

prod_auth_header() {
  printf '%s:%s' "${PROD_USER}" "${PROD_PASS}" | base64 -w0
}

prod_api() {
  local method="$1"; local path="$2"; shift 2
  curl -sk -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" -X "${method}" \
    -H "Authorization: Basic $(prod_auth_header)" \
    "${@}" "${PROD_URL}${path}"
}

prod_crumb() {
  prod_api GET /crumbIssuer/api/json |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["crumbRequestField"], d["crumb"])'
}

get_prod_job_xml() {
  local job_name="$1"
  prod_api GET "/job/${TARGET_FOLDER}/job/${job_name}/config.xml"
}

update_prod_job_xml() {
  local job_name="$1" xml_file="$2"
  read -r crumb_field crumb < <(prod_crumb)
  local http_code
  http_code=$(prod_api POST "/job/${TARGET_FOLDER}/job/${job_name}/config.xml" \
    -H "Content-Type: application/xml" \
    -H "${crumb_field}: ${crumb}" \
    --data-binary @"${xml_file}" \
    -o /dev/null -w '%{http_code}')
  echo "${http_code}"
}

transform_xml() {
  local input="$1" output="$2"
  python3 - "${input}" "${output}" <<'PYEOF'
import sys, re

xml = open(sys.argv[1], "r").read()

# --- environment variables (XML-escaped Groovy inside <script> tags) ---

# gitBranchName: any value -> master
xml = re.sub(
    r"(gitBranchName\s*=\s*&apos;)[^&]*(&apos;)",
    r"\g<1>master\g<2>",
    xml,
)

# namespaceName: any value -> myrace-production
xml = re.sub(
    r"(namespaceName\s*=\s*&apos;)[^&]*(&apos;)",
    r"\g<1>myrace-production\g<2>",
    xml,
)

# registryUrl: any value -> 172.17.105.17
xml = re.sub(
    r"(registryUrl\s*=\s*&apos;)[^&]*(&apos;)",
    r"\g<1>172.17.105.17\g<2>",
    xml,
)

# registryCredential: any value -> harbor_production_credential
xml = re.sub(
    r"(registryCredential\s*=\s*&apos;)[^&]*(&apos;)",
    r"\g<1>harbor_production_credential\g<2>",
    xml,
)

# Helm deploy: k8s-uat-1.yml -> k8s-production-1.yml, k8s-uat-2.yml -> k8s-production-2.yml, k8s-uat.yml -> k8s-production.yml
xml = re.sub(r"k8s-uat(-\d+)?\.yml", lambda m: f"k8s-production{m.group(1) or ''}.yml", xml)
xml = re.sub(r"k8s-uat(-\d+)?\.yaml", lambda m: f"k8s-production{m.group(1) or ''}.yaml", xml)

# Stage names: [staging] / [uat] / [beta] -> [production]  (inside &quot;...&quot;)
xml = re.sub(r"\[staging\]", "[production]", xml, flags=re.IGNORECASE)
xml = re.sub(r"\[uat\]", "[production]", xml, flags=re.IGNORECASE)
xml = re.sub(r"\[beta\]", "[production]", xml, flags=re.IGNORECASE)

# Docker build arg PROFILE=uat -> PROFILE=production
xml = re.sub(r"PROFILE=uat", "PROFILE=production", xml)

open(sys.argv[2], "w").write(xml)
PYEOF
}

main() {
  echo "=== Updating RACE-PRODUCTION pipeline configs ==="

  local jobs_json
  jobs_json=$(prod_api GET "/job/${TARGET_FOLDER}/api/json?tree=jobs%5Bname%5D")
  local jobs=()
  mapfile -t jobs < <(echo "${jobs_json}" | python3 -c '
import json, sys
for j in json.load(sys.stdin)["jobs"]:
    print(j["name"])
')

  echo "Found ${#jobs[@]} jobs"
  echo ""

  local failed=0
  for job in "${jobs[@]}"; do
    local tmp_in="/tmp/prod_job_in.xml"
    local tmp_out="/tmp/prod_job_out.xml"

    get_prod_job_xml "${job}" > "${tmp_in}"

    if ! grep -q 'flow-definition\|project' "${tmp_in}"; then
      echo "  SKIP ${job} (not a pipeline/freestyle job)"
      continue
    fi

    transform_xml "${tmp_in}" "${tmp_out}"

    if diff -q "${tmp_in}" "${tmp_out}" > /dev/null 2>&1; then
      echo "  SKIP ${job} (no changes needed)"
      continue
    fi

    local http_code
    http_code=$(update_prod_job_xml "${job}" "${tmp_out}")

    if [[ "${http_code}" == "200" || "${http_code}" == "302" ]]; then
      echo "  OK   ${job}"
    else
      echo "  FAIL ${job} (HTTP ${http_code})"
      failed=$((failed + 1))
    fi

    rm -f "${tmp_in}" "${tmp_out}"
  done

  echo ""
  echo "=== Verification ==="
  for job in "${jobs[@]}"; do
    local xml
    xml=$(get_prod_job_xml "${job}")
    local branch ns reg_url reg_cred
    branch=$(echo "${xml}" | python3 -c "
import sys, re
m = re.search(r\"gitBranchName\s*=\s*&apos;([^&]*)&apos;\", sys.stdin.read())
print(m.group(1) if m else 'N/A')
")
    ns=$(echo "${xml}" | python3 -c "
import sys, re
m = re.search(r\"namespaceName\s*=\s*&apos;([^&]*)&apos;\", sys.stdin.read())
print(m.group(1) if m else 'N/A')
")
    reg_url=$(echo "${xml}" | python3 -c "
import sys, re
m = re.search(r\"registryUrl\s*=\s*&apos;([^&]*)&apos;\", sys.stdin.read())
print(m.group(1) if m else 'N/A')
")
    reg_cred=$(echo "${xml}" | python3 -c "
import sys, re
m = re.search(r\"registryCredential\s*=\s*&apos;([^&]*)&apos;\", sys.stdin.read())
print(m.group(1) if m else 'N/A')
")
    printf "  %-45s branch=%-10s ns=%-20s registry=%-18s cred=%s\n" \
      "${job}" "${branch}" "${ns}" "${reg_url}" "${reg_cred}"
  done

  if [[ "${failed}" -gt 0 ]]; then
    echo ""
    echo "${failed} job(s) failed to update" >&2
    exit 1
  fi

  echo ""
  echo "=== All production pipelines updated ==="
}

main "$@"
