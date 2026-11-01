#!/usr/bin/env bash
# Make sure an HCP Terraform workspace exists and uses local execution: HCP keeps
# the state and lock, and the run happens in GitHub Actions, where the GCP login is.
#
# Usage: TF_TOKEN_app_terraform_io=... scripts/hcp_workspace.sh WORKSPACE
set -euo pipefail

WORKSPACE="${1:?usage: scripts/hcp_workspace.sh WORKSPACE}"
API="https://app.terraform.io/api/v2/organizations/Housefull/workspaces"
BODY="{\"data\":{\"type\":\"workspaces\",\"attributes\":{\"name\":\"$WORKSPACE\",\"execution-mode\":\"local\"}}}"
AUTH="Authorization: Bearer ${TF_TOKEN_app_terraform_io:?}"
TYPE="Content-Type: application/vnd.api+json"

code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H "$TYPE" -d "$BODY" "$API")"
if [ "$code" != "201" ]; then
  curl -fsS -o /dev/null -X PATCH -H "$AUTH" -H "$TYPE" -d "$BODY" "$API/$WORKSPACE"
fi
