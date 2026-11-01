#!/usr/bin/env bash
# One-time setup that lets GitHub Actions reach Google Cloud without a stored key.
# Run once, from main, as a project owner. Safe to rerun. Terraform takes these
# resources over afterwards. See docs/build-log.md, entry 6.
#
# Usage: scripts/bootstrap_gcp.sh PROJECT_ID
set -euo pipefail

PROJECT_ID="${1:?usage: scripts/bootstrap_gcp.sh PROJECT_ID}"
# The numeric id, not the name: a name can be reused if the repo is renamed,
# but this id always belongs to this repo.
GITHUB_REPO_ID="1441963170"
POOL="github"
PROVIDER="github"
PLAN_SA="housefull-plan"
DEPLOY_SA="housefull-deploy"

APIS=(
  artifactregistry.googleapis.com
  cloudresourcemanager.googleapis.com
  cloudscheduler.googleapis.com
  compute.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  logging.googleapis.com
  monitoring.googleapis.com
  pubsub.googleapis.com
  run.googleapis.com
  secretmanager.googleapis.com
  servicenetworking.googleapis.com
  serviceusage.googleapis.com
  sqladmin.googleapis.com
  sts.googleapis.com
)

PLAN_ROLES=(
  roles/viewer
  roles/iam.securityReviewer
)

DEPLOY_ROLES=(
  roles/artifactregistry.admin
  roles/cloudscheduler.admin
  roles/cloudsql.admin
  roles/compute.admin
  roles/iam.serviceAccountAdmin
  roles/iam.serviceAccountUser
  roles/iam.workloadIdentityPoolAdmin
  roles/logging.admin
  roles/monitoring.admin
  roles/pubsub.admin
  roles/resourcemanager.projectIamAdmin
  roles/run.admin
  roles/secretmanager.admin
  roles/servicenetworking.networksAdmin
  roles/serviceusage.serviceUsageAdmin
)

create_service_account() {
  local name="$1" display_name="$2"
  if ! gcloud iam service-accounts describe "$name@$PROJECT_ID.iam.gserviceaccount.com" \
    --project "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$name" \
      --project "$PROJECT_ID" --display-name "$display_name"
  fi
}

grant_roles() {
  local name="$1"
  shift
  local role
  for role in "$@"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member "serviceAccount:$name@$PROJECT_ID.iam.gserviceaccount.com" \
      --role "$role" --condition None --quiet >/dev/null
  done
}

allow_github() {
  local name="$1" principal="$2"
  gcloud iam service-accounts add-iam-policy-binding \
    "$name@$PROJECT_ID.iam.gserviceaccount.com" \
    --project "$PROJECT_ID" \
    --role roles/iam.workloadIdentityUser \
    --member "$principal" --condition None --quiet >/dev/null
}

echo "Turning on APIs"
gcloud services enable "${APIS[@]}" --project "$PROJECT_ID"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format 'value(projectNumber)')"
POOL_PATH="projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL"

echo "Creating the Workload Identity pool"
if ! gcloud iam workload-identity-pools describe "$POOL" \
  --project "$PROJECT_ID" --location global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$POOL" \
    --project "$PROJECT_ID" --location global --display-name "GitHub Actions"
fi

if ! gcloud iam workload-identity-pools providers describe "$PROVIDER" \
  --project "$PROJECT_ID" --location global \
  --workload-identity-pool "$POOL" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --project "$PROJECT_ID" --location global \
    --workload-identity-pool "$POOL" \
    --display-name "GitHub Actions" \
    --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "google.subject=assertion.sub,attribute.repository_id=assertion.repository_id,attribute.ref=assertion.ref" \
    --attribute-condition "assertion.repository_id == '$GITHUB_REPO_ID'"
fi

echo "Creating service accounts"
create_service_account "$PLAN_SA" "Housefull read-only plan"
create_service_account "$DEPLOY_SA" "Housefull deploy"
# A new service account can take a few seconds to be usable in IAM.
sleep 15

echo "Granting roles"
grant_roles "$PLAN_SA" "${PLAN_ROLES[@]}"
grant_roles "$DEPLOY_SA" "${DEPLOY_ROLES[@]}"

echo "Allowing GitHub to use the service accounts"
allow_github "$PLAN_SA" \
  "principalSet://iam.googleapis.com/$POOL_PATH/attribute.repository_id/$GITHUB_REPO_ID"
allow_github "$DEPLOY_SA" \
  "principalSet://iam.googleapis.com/$POOL_PATH/attribute.ref/refs/heads/main"

echo
echo "Done. Add these as GitHub Actions variables (they are not secrets):"
echo "GCP_PROJECT_ID=$PROJECT_ID"
echo "GCP_WORKLOAD_IDENTITY_PROVIDER=$POOL_PATH/providers/$PROVIDER"
echo "GCP_PLAN_SERVICE_ACCOUNT=$PLAN_SA@$PROJECT_ID.iam.gserviceaccount.com"
echo "GCP_DEPLOY_SERVICE_ACCOUNT=$DEPLOY_SA@$PROJECT_ID.iam.gserviceaccount.com"
