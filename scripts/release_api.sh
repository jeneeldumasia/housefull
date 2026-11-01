#!/usr/bin/env bash
# Release a new API version gradually, and go back if it misbehaves.
#
# Usage: scripts/release_api.sh IMAGE BASE_URL   (needs REGION in the environment)
set -euo pipefail

IMAGE="${1:?usage: scripts/release_api.sh IMAGE BASE_URL}"
BASE_URL="${2:?usage: scripts/release_api.sh IMAGE BASE_URL}"
SERVICE="housefull-api"
CANARY_PERCENT=10
CANARY_REQUESTS=200
MAX_SERVER_ERRORS=0

describe() {
  gcloud run services describe "$SERVICE" --region "$REGION" --format "$1"
}

previous_image="$(describe 'value(spec.template.spec.containers[0].image)')"
previous_revision="$(describe 'value(status.traffic[0].revisionName)')"

# A revision that fails its startup check stops here, having taken no traffic.
gcloud run deploy "$SERVICE" --region "$REGION" --image "$IMAGE" --no-traffic --quiet
new_revision="$(describe 'value(status.latestCreatedRevisionName)')"

# The first real release has nothing worth protecting, and the certificate may
# not be ready, so the public address can't be tested yet.
if [[ "$previous_image" == *"cloudrun/container/hello"* ]]; then
  echo "First release: sending all traffic to $new_revision"
  gcloud run services update-traffic "$SERVICE" --region "$REGION" --to-latest --quiet
  exit 0
fi

roll_back() {
  echo "Rolling back to $previous_revision: $1" >&2
  gcloud run services update-traffic "$SERVICE" --region "$REGION" \
    --to-revisions "$previous_revision=100" --quiet
  exit 1
}

echo "Sending $CANARY_PERCENT% of traffic to $new_revision"
gcloud run services update-traffic "$SERVICE" --region "$REGION" \
  --to-revisions "$new_revision=$CANARY_PERCENT" --quiet

failures=0
for _ in $(seq 1 "$CANARY_REQUESTS"); do
  status="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$BASE_URL/health" || true)"
  [ "$status" = "200" ] || failures=$((failures + 1))
done
echo "$failures of $CANARY_REQUESTS requests failed"
[ "$failures" -le "$MAX_SERVER_ERRORS" ] || roll_back "health requests failed"

# Logs take a moment to arrive.
sleep 45
logs() {
  gcloud logging read \
    "resource.type=\"cloud_run_revision\" resource.labels.revision_name=\"$new_revision\" $1" \
    --freshness 15m --limit 500 --format 'value(insertId)' | wc -l
}
served="$(logs 'httpRequest.status>0')"
errors="$(logs 'httpRequest.status>=500')"
echo "$new_revision served $served requests with $errors server errors"
# Zero requests would mean the new version was never tested at all.
[ "$served" -gt 0 ] || roll_back "the new revision received no traffic"
[ "$errors" -le "$MAX_SERVER_ERRORS" ] || roll_back "the new revision returned server errors"

gcloud run services update-traffic "$SERVICE" --region "$REGION" --to-latest --quiet
echo "Released $new_revision"
