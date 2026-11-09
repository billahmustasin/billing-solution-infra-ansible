#!/usr/bin/env bash
# Copy all RACE-UAT jobs from UAT Jenkins to production Jenkins as RACE-PRODUCTION/*-production
set -euo pipefail

UAT_CLI_DIR="${UAT_CLI_DIR:-/home/bs01441/myrace}"
UAT_JENKINS_CLI=(java -jar "${UAT_CLI_DIR}/jenkins-cli.jar"
  -s http://103.143.148.165:9002
  -auth admin:race@bs23)

PROD_URL="${JENKINS_PROD_URL:-https://45.114.84.54}"
PROD_USER="${JENKINS_PROD_USER:-myrace-admin}"
PROD_PASS="${JENKINS_PROD_PASS:?Set JENKINS_PROD_PASS}"

SOURCE_FOLDER="RACE-UAT"
TARGET_FOLDER="RACE-PRODUCTION"
JOB_SUFFIX="-production"

COOKIE_JAR=$(mktemp)
trap 'rm -f "${COOKIE_JAR}"' EXIT

prod_auth_header() {
  printf '%s:%s' "${PROD_USER}" "${PROD_PASS}" | base64 -w0
}

prod_api() {
  local method="$1"
  local path="$2"
  shift 2
  curl -sk -c "${COOKIE_JAR}" -b "${COOKIE_JAR}" -X "${method}" \
    -H "Authorization: Basic $(prod_auth_header)" \
    "${@}" \
    "${PROD_URL}${path}"
}

prod_crumb() {
  prod_api GET /crumbIssuer/api/json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["crumbRequestField"], d["crumb"])'
}

folder_exists() {
  local code
  code=$(prod_api HEAD "/job/${TARGET_FOLDER}/" -o /dev/null -w '%{http_code}')
  [[ "${code}" == "200" ]]
}

job_exists() {
  local job_name="$1"
  local code
  code=$(prod_api HEAD "/job/${TARGET_FOLDER}/job/${job_name}/" -o /dev/null -w '%{http_code}')
  [[ "${code}" == "200" ]]
}

create_folder() {
  if folder_exists; then
    echo "Folder ${TARGET_FOLDER} already exists"
    return 0
  fi

  echo "Creating folder ${TARGET_FOLDER}..."
  read -r crumb_field crumb < <(prod_crumb)
  local tmp
  tmp=$(mktemp)
  "${UAT_JENKINS_CLI[@]}" get-job "${SOURCE_FOLDER}" > "${tmp}"

  local http_code
  http_code=$(prod_api POST "/createItem?name=${TARGET_FOLDER}" \
    -H "Content-Type: application/xml" \
    -H "${crumb_field}: ${crumb}" \
    --data-binary @"${tmp}" \
    -o /dev/null -w '%{http_code}')
  rm -f "${tmp}"

  if [[ "${http_code}" != "200" && "${http_code}" != "302" ]]; then
    echo "Failed to create folder ${TARGET_FOLDER} (HTTP ${http_code})" >&2
    exit 1
  fi
  echo "Folder ${TARGET_FOLDER} created"
}

copy_job() {
  local source_job="$1"
  local target_job="${source_job}${JOB_SUFFIX}"
  local tmp

  if job_exists "${target_job}"; then
    echo "  SKIP ${target_job} (already exists)"
    return 0
  fi

  echo "  COPY ${source_job} -> ${TARGET_FOLDER}/${target_job}"
  tmp=$(mktemp)
  "${UAT_JENKINS_CLI[@]}" get-job "${SOURCE_FOLDER}/${source_job}" > "${tmp}"

  read -r crumb_field crumb < <(prod_crumb)
  local http_code
  http_code=$(prod_api POST "/job/${TARGET_FOLDER}/createItem?name=${target_job}" \
    -H "Content-Type: application/xml" \
    -H "${crumb_field}: ${crumb}" \
    --data-binary @"${tmp}" \
    -o /dev/null -w '%{http_code}')
  rm -f "${tmp}"

  if [[ "${http_code}" != "200" && "${http_code}" != "302" ]]; then
    echo "  FAILED ${target_job} (HTTP ${http_code})" >&2
    return 1
  fi
}

main() {
  echo "=== Jenkins job migration: ${SOURCE_FOLDER} -> ${TARGET_FOLDER} ==="
  create_folder

  local jobs=()
  mapfile -t jobs < <("${UAT_JENKINS_CLI[@]}" list-jobs "${SOURCE_FOLDER}")
  echo "Found ${#jobs[@]} jobs in ${SOURCE_FOLDER}"

  local failed=0
  for job in "${jobs[@]}"; do
    copy_job "${job}" || failed=$((failed + 1))
  done

  echo ""
  echo "=== Done ==="
  prod_api GET "/job/${TARGET_FOLDER}/api/json?tree=jobs%5Bname%5D" | python3 -c '
import json, sys
data = json.load(sys.stdin)
names = sorted(j["name"] for j in data.get("jobs", []))
url = data.get("url", "RACE-PRODUCTION")
print(f"Jobs in {url}: {len(names)}")
for name in names:
    print(f"  - {name}")
'

  if [[ "${failed}" -gt 0 ]]; then
    echo "${failed} job(s) failed" >&2
    exit 1
  fi
}

main "$@"
