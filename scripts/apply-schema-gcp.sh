#!/bin/bash
set -euo pipefail
umask 077

if [[ $# -ne 1 ]]; then
  printf 'Usage: bash scripts/apply-schema-gcp.sh REGISTRY/IMAGE@sha256:DIGEST\n' >&2
  exit 2
fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=$1
TIMEOUT=${SCHEMA_TIMEOUT_SECONDS:-900}
POLL=${SCHEMA_POLL_SECONDS:-10}
[[ "$TIMEOUT" =~ ^[1-9][0-9]{0,4}$ && "$POLL" =~ ^[1-9][0-9]{0,3}$ ]] || {
  printf 'Invalid schema timeout or poll interval.\n' >&2
  exit 2
}
for tool in terraform jq gcloud; do
  command -v "$tool" >/dev/null || { printf 'Missing command: %s\n' "$tool" >&2; exit 2; }
done

DEPLOYMENT=$(terraform -chdir="$ROOT/infra" output -json deployment | jq -ce '
  select(type == "object") |
  select(.project_id | type == "string" and test("^[a-z][a-z0-9-]{4,61}[a-z0-9]$")) |
  select(.region | type == "string" and test("^[a-z]+-[a-z]+[0-9]+$")) |
  select(.subnetwork | type == "string" and test("^(https://www.googleapis.com/compute/v1/)?projects/[a-z0-9-]+/regions/[a-z0-9-]+/subnetworks/[a-z0-9-]+$")) |
  select(.schema_service_account | type == "string" and test("^[a-z0-9-]+@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$")) |
  select(.runtime_secret_id | type == "string" and test("^[A-Za-z0-9_-]{1,255}$")) |
  select(.db_host | type == "string" and test("^[A-Za-z0-9.-]+$")) |
  select(.db_name | type == "string" and test("^[A-Za-z0-9_]+$")) |
  select(.registry | type == "string" and test("^[a-z0-9-]+-docker\\.pkg\\.dev/[a-z0-9-]+/[a-z0-9_-]+$")) |
  select(.zones | type == "array" and length > 0) |
  select(all(.zones[]; type == "string" and test("^[a-z]+-[a-z]+[0-9]+-[a-z]$"))) |
  select(.region as $region | all(.zones[]; startswith($region + "-")))
')
PROJECT=$(jq -r '.project_id' <<< "$DEPLOYMENT")
REGION=$(jq -r '.region' <<< "$DEPLOYMENT")
SUBNETWORK=$(jq -r '.subnetwork' <<< "$DEPLOYMENT")
ACCOUNT=$(jq -r '.schema_service_account' <<< "$DEPLOYMENT")
SECRET=$(jq -r '.runtime_secret_id' <<< "$DEPLOYMENT")
DB_HOST=$(jq -r '.db_host' <<< "$DEPLOYMENT")
DB_NAME=$(jq -r '.db_name' <<< "$DEPLOYMENT")
REGISTRY=$(jq -r '.registry' <<< "$DEPLOYMENT")
ZONE=$(jq -r '.zones[0]' <<< "$DEPLOYMENT")
[[ "$SUBNETWORK" == *"/projects/$PROJECT/regions/$REGION/"* || "$SUBNETWORK" == "projects/$PROJECT/regions/$REGION/"* ]] || exit 2
[[ "$IMAGE" == "$REGISTRY/"* && "${IMAGE#"$REGISTRY/"}" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*@sha256:[a-f0-9]{64}$ ]] || {
  printf 'Image must belong to deployment.registry and use an immutable sha256 digest.\n' >&2
  exit 2
}

VM="schema-$(date +%s)-${RANDOM}"
CREATED=0
cleanup() {
  local result=$?
  trap - EXIT
  if [[ "$CREATED" -eq 1 ]]; then
    if ! gcloud compute instances delete "$VM" --project="$PROJECT" --zone="$ZONE" --quiet; then
      printf 'Cleanup failed; delete instance %s in project %s, zone %s.\n' "$VM" "$PROJECT" "$ZONE" >&2
      result=1
    fi
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CREATED=1
gcloud compute instances create "$VM" --project="$PROJECT" --zone="$ZONE" --quiet \
  --machine-type=e2-small --image-family=cos-stable --image-project=cos-cloud \
  --subnet="$SUBNETWORK" --no-address --service-account="$ACCOUNT" \
  --scopes=https://www.googleapis.com/auth/cloud-platform \
  --metadata="enable-guest-attributes=TRUE,schema-image=$IMAGE,schema-registry=${REGISTRY%%/*},schema-project=$PROJECT,schema-secret=$SECRET,schema-db-host=$DB_HOST,schema-db-name=$DB_NAME" \
  --metadata-from-file="startup-script=$ROOT/scripts/schema-startup.sh.tftpl" >/dev/null

DEADLINE=$((SECONDS + TIMEOUT))
GUEST_ATTRIBUTES='{}'
while (( SECONDS < DEADLINE )); do
  GUEST_ATTRIBUTES=$(gcloud compute instances get-guest-attributes "$VM" --project="$PROJECT" --zone="$ZONE" \
    --query-path=schema --format=json 2>/dev/null || true)
  STATUS=$(jq -er '[.queryValue.items[]? | select(.key == "status") | .value] | if length == 1 then .[0] else empty end' <<< "$GUEST_ATTRIBUTES" 2>/dev/null || true)
  case "$STATUS" in
    success) printf 'Schema applied successfully.\n'; exit 0 ;;
    failed)
      FAILURE_STAGE=$(jq -er '[.queryValue.items[]? | select(.key == "failure-stage") | .value] | if length == 1 then .[0] else empty end' <<< "$GUEST_ATTRIBUTES" 2>/dev/null || true)
      case "$FAILURE_STAGE" in
        startup|docker|metadata|image-pull|secret-access|schema-apply) ;;
        *) FAILURE_STAGE=unknown ;;
      esac
      printf 'Schema task failed during %s.\n' "$FAILURE_STAGE" >&2
      exit 1 ;;
    '') ;;
    *) printf 'Unexpected schema task status.\n' >&2; exit 1 ;;
  esac
  REMAINING=$((DEADLINE - SECONDS))
  (( REMAINING > 0 )) || break
  INTERVAL=$POLL
  (( INTERVAL <= REMAINING )) || INTERVAL=$REMAINING
  sleep "$INTERVAL"
done
LAST_STAGE=$(jq -er '[.queryValue.items[]? | select(.key == "stage") | .value] | if length == 1 then .[0] else empty end' <<< "$GUEST_ATTRIBUTES" 2>/dev/null || true)
case "$LAST_STAGE" in
  startup|docker|metadata|image-pull|secret-access|schema-apply) ;;
  *) LAST_STAGE=unknown ;;
esac
printf 'Timed out waiting for schema task during %s.\n' "$LAST_STAGE" >&2
exit 1