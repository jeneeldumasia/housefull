# This access lives in its own stack so that tearing the app down for the night
# can never remove GitHub's ability to bring it back up.

data "google_project" "this" {}

locals {
  plan_roles = toset([
    "roles/iam.securityReviewer",
    "roles/viewer",
  ])

  deploy_roles = toset([
    "roles/artifactregistry.admin",
    "roles/cloudscheduler.admin",
    "roles/cloudsql.admin",
    "roles/compute.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/logging.admin",
    "roles/monitoring.admin",
    "roles/pubsub.admin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/run.admin",
    "roles/secretmanager.admin",
    "roles/servicenetworking.networksAdmin",
    "roles/serviceusage.serviceUsageAdmin",
  ])

  pool_path = google_iam_workload_identity_pool.github.name
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub Actions"
  attribute_condition                = "assertion.repository_id == '${var.github_repository_id}'"

  attribute_mapping = {
    "google.subject"          = "assertion.sub"
    "attribute.repository_id" = "assertion.repository_id"
    "attribute.ref"           = "assertion.ref"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "plan" {
  account_id   = "housefull-plan"
  display_name = "Housefull read-only plan"
}

resource "google_service_account" "deploy" {
  account_id   = "housefull-deploy"
  display_name = "Housefull deploy"
}

resource "google_project_iam_member" "plan" {
  for_each = local.plan_roles

  project = var.project_id
  role    = each.value
  member  = google_service_account.plan.member
}

resource "google_project_iam_member" "deploy" {
  for_each = local.deploy_roles

  project = var.project_id
  role    = each.value
  member  = google_service_account.deploy.member
}

resource "google_service_account_iam_member" "plan_github" {
  service_account_id = google_service_account.plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.pool_path}/attribute.repository_id/${var.github_repository_id}"
}

resource "google_service_account_iam_member" "deploy_github" {
  service_account_id = google_service_account.deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.pool_path}/attribute.ref/refs/heads/main"
}
