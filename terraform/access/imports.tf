# These resources were created once by scripts/bootstrap_gcp.sh. Importing them
# puts them under Terraform, so later changes go through pull requests.

locals {
  plan_email   = "housefull-plan@${var.project_id}.iam.gserviceaccount.com"
  deploy_email = "housefull-deploy@${var.project_id}.iam.gserviceaccount.com"
  pool_id      = "projects/${var.project_id}/locations/global/workloadIdentityPools/github"
  pool_member  = "principalSet://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/github"
}

import {
  to = google_iam_workload_identity_pool.github
  id = local.pool_id
}

import {
  to = google_iam_workload_identity_pool_provider.github
  id = "${local.pool_id}/providers/github"
}

import {
  to = google_service_account.plan
  id = "projects/${var.project_id}/serviceAccounts/${local.plan_email}"
}

import {
  to = google_service_account.deploy
  id = "projects/${var.project_id}/serviceAccounts/${local.deploy_email}"
}

import {
  for_each = local.plan_roles
  to       = google_project_iam_member.plan[each.value]
  id       = "${var.project_id} ${each.value} serviceAccount:${local.plan_email}"
}

import {
  for_each = local.deploy_roles
  to       = google_project_iam_member.deploy[each.value]
  id       = "${var.project_id} ${each.value} serviceAccount:${local.deploy_email}"
}

import {
  to = google_service_account_iam_member.plan_github
  id = "projects/${var.project_id}/serviceAccounts/${local.plan_email} roles/iam.workloadIdentityUser ${local.pool_member}/attribute.repository_id/${var.github_repository_id}"
}

import {
  to = google_service_account_iam_member.deploy_github
  id = "projects/${var.project_id}/serviceAccounts/${local.deploy_email} roles/iam.workloadIdentityUser ${local.pool_member}/attribute.ref/refs/heads/main"
}
