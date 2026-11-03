#!/bin/bash
set -euo pipefail
umask 077
STAGE=prerequisites
trap 'printf "Schema operation failed during %s.\n" "$STAGE" >&2' ERR

if [[ $# -ne 1 ]]; then
  printf 'Usage: bash scripts/apply-schema-gcp.sh REGISTRY/IMAGE@sha256:DIGEST\n' >&2
  exit 2
fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=$1
ATTEMPTS=${SCHEMA_CONNECT_ATTEMPTS:-15}
[[ "$ATTEMPTS" =~ ^[1-9][0-9]?$ ]] && (( ATTEMPTS <= 60 )) || {
  printf 'Invalid schema connection attempts.\n' >&2
  exit 2
}
for tool in terraform jq gcloud docker; do
  command -v "$tool" >/dev/null || { printf 'Missing command: %s\n' "$tool" >&2; exit 2; }
done

STAGE=deployment-output
DEPLOYMENT=$(terraform -chdir="$ROOT/infra" output -json deployment | jq -ce '
  select(type == "object") |
  select(.project_id | type == "string" and test("^[a-z][a-z0-9-]{4,61}[a-z0-9]$")) |
  select(.region | type == "string" and test("^[a-z]+-[a-z]+[0-9]+$")) |
  select(.db_connection_name | type == "string" and test("^[a-z][a-z0-9-]{4,61}[a-z0-9]:[a-z]+-[a-z]+[0-9]+:[a-z][a-z0-9-]{0,61}[a-z0-9]$")) |
  select(.runtime_secret_id | type == "string" and test("^[A-Za-z0-9_-]{1,255}$")) |
  select(.db_host | type == "string" and test("^[A-Za-z0-9.-]+$")) |
  select(.db_name | type == "string" and test("^[A-Za-z0-9_]+$")) |
  select(.registry | type == "string" and test("^[a-z0-9-]+-docker\\.pkg\\.dev/[a-z0-9-]+/[a-z0-9_-]+$"))
')
PROJECT=$(jq -r '.project_id' <<< "$DEPLOYMENT")
REGION=$(jq -r '.region' <<< "$DEPLOYMENT")
CONNECTION_NAME=$(jq -r '.db_connection_name' <<< "$DEPLOYMENT")
SECRET=$(jq -r '.runtime_secret_id' <<< "$DEPLOYMENT")
DB_NAME=$(jq -r '.db_name' <<< "$DEPLOYMENT")
REGISTRY=$(jq -r '.registry' <<< "$DEPLOYMENT")
STAGE=image-validation
[[ "$IMAGE" == "$REGISTRY/"* && "${IMAGE#"$REGISTRY/"}" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*@sha256:[a-f0-9]{64}$ ]] || {
  printf 'Schema operation failed during image-validation.\n' >&2
  printf 'Image must belong to deployment.registry and use an immutable sha256 digest.\n' >&2
  exit 2
}

CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS:-${GOOGLE_GHA_CREDS_PATH:-}}
if [[ -z "$CREDENTIALS" && -n "${HOME:-}" ]]; then
  CREDENTIALS="$HOME/.config/gcloud/application_default_credentials.json"
fi
[[ -r "$CREDENTIALS" ]] || {
  printf 'Schema operation failed during credentials.\n' >&2
  exit 1
}

WORK_ROOT=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
WORK="$WORK_ROOT/schema-task-$$-${RANDOM}"
STAGE=workspace
mkdir -m 700 -- "$WORK"
ENV_FILE="$WORK/mysql.env"
NETWORK="schema-net-$$-${RANDOM}"
PROXY="schema-proxy-$$-${RANDOM}"
PROXY_IMAGE=gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.27.0
NETWORK_CREATED=0
PROXY_CREATED=0
cleanup() {
  local result=$?
  local cleanup_failed=0
  trap - EXIT
  if [[ "$PROXY_CREATED" -eq 1 ]] && ! docker rm --force "$PROXY" >/dev/null 2>&1; then
    cleanup_failed=1
  fi
  if [[ "$NETWORK_CREATED" -eq 1 ]] && ! docker network rm "$NETWORK" >/dev/null 2>&1; then cleanup_failed=1; fi
  rm -rf -- "$WORK"
  if [[ "$cleanup_failed" -eq 1 ]]; then
    printf 'Schema operation failed during cleanup.\n' >&2
    result=1
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
STAGE=secret-fetch
if ! SECRET_PAYLOAD=$(gcloud secrets versions access latest --secret="$SECRET" --project="$PROJECT" 2>/dev/null); then
  printf 'Schema operation failed during secret-fetch.\n' >&2
  exit 1
fi
if ! DB_USER=$(jq -er '.DB_USER | select(type == "string" and test("^[A-Za-z0-9_]+$"))' <<< "$SECRET_PAYLOAD" 2>/dev/null) || \
  ! DB_PASSWORD=$(jq -er '.DB_PASSWORD | select(type == "string" and test("^[A-Za-z0-9]+$"))' <<< "$SECRET_PAYLOAD" 2>/dev/null); then
  unset SECRET_PAYLOAD
  printf 'Schema operation failed during secret-fetch.\n' >&2
  exit 1
fi
unset SECRET_PAYLOAD
printf 'DB_HOST=cloud-sql-proxy\nDB_PORT=3306\nDB_NAME=%s\nDB_USER=%s\nDB_PASSWORD=%s\n' \
  "$DB_NAME" "$DB_USER" "$DB_PASSWORD" > "$ENV_FILE"
unset DB_PASSWORD
chmod 600 "$ENV_FILE"

STAGE=proxy-start
if ! docker network create "$NETWORK" >/dev/null 2>&1; then
  printf 'Schema operation failed during proxy-start.\n' >&2
  exit 1
fi
NETWORK_CREATED=1
PROXY_CREATED=1
if ! docker run --detach --name "$PROXY" --network "$NETWORK" --network-alias cloud-sql-proxy \
  --mount "type=bind,src=$CREDENTIALS,dst=/credentials.json,readonly" \
  "$PROXY_IMAGE" --address 0.0.0.0 --port 3306 --credentials-file /credentials.json "$CONNECTION_NAME" \
  >/dev/null 2>&1; then
  printf 'Schema operation failed during proxy-start.\n' >&2
  exit 1
fi

STAGE=schema-apply
for attempt in $(seq 1 "$ATTEMPTS"); do
  if docker run --rm --network "$NETWORK" --log-driver none --env-file "$ENV_FILE" \
    --entrypoint node "$IMAGE" src/db/apply-schema.js >/dev/null 2>&1; then
    printf 'Schema applied successfully.\n'
    exit 0
  fi
  if (( attempt < ATTEMPTS )); then sleep 2; fi
done
printf 'Schema operation failed during schema-apply.\n' >&2
exit 1