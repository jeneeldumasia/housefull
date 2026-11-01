variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "image" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "database_url_secret" {
  type = string
}

variable "bookings_topic_id" {
  type = string
}

variable "bookings_topic_name" {
  type = string
}

locals {
  # db-f1-micro allows about 25 connections, with a few reserved. These limits
  # keep the total under that: (3 x 4) + (2 x 3) + 2 for jobs = 20.
  api_max_instances    = 3
  api_pool_size        = 4
  worker_max_instances = 2
  worker_pool_size     = 3

  accounts = {
    api       = "housefull-api"
    worker    = "housefull-worker"
    jobs      = "housefull-jobs"
    scheduler = "housefull-scheduler"
    pubsub    = "housefull-pubsub-push"
  }
}

# One identity per job, so each gets only what it needs.
resource "google_service_account" "this" {
  for_each = local.accounts

  account_id = each.value
}

resource "random_password" "jwt" {
  length  = 64
  special = false
}

resource "google_secret_manager_secret" "jwt" {
  secret_id = "housefull-jwt-secret"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "jwt" {
  secret      = google_secret_manager_secret.jwt.id
  secret_data = random_password.jwt.result
}

resource "google_secret_manager_secret_iam_member" "database_url" {
  for_each = toset(["api", "worker", "jobs"])

  secret_id = var.database_url_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.this[each.value].member
}

resource "google_secret_manager_secret_iam_member" "jwt" {
  secret_id = google_secret_manager_secret.jwt.id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.this["api"].member
}

resource "google_pubsub_topic_iam_member" "api_publishes" {
  topic  = var.bookings_topic_id
  role   = "roles/pubsub.publisher"
  member = google_service_account.this["api"].member
}

resource "google_cloud_run_v2_service" "api" {
  name                = "housefull-api"
  location            = var.region
  deletion_protection = false

  # Traffic must come through the load balancer. The run.app address is refused,
  # so there's no way around it. That makes IAM on this service redundant, and
  # avoids granting allUsers, which organization policies often block.
  ingress              = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  invoker_iam_disabled = true

  template {
    service_account                  = google_service_account.this["api"].email
    max_instance_request_concurrency = 20

    scaling {
      min_instance_count = 0
      max_instance_count = local.api_max_instances
    }

    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        subnetwork = var.subnet_id
      }
    }

    containers {
      image = var.image

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "PUBSUB_TOPIC"
        value = var.bookings_topic_name
      }
      env {
        name  = "DB_POOL_SIZE"
        value = tostring(local.api_pool_size)
      }
      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = var.database_url_secret
            version = "latest"
          }
        }
      }
      env {
        name = "JWT_SECRET"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.jwt.secret_id
            version = "latest"
          }
        }
      }

      startup_probe {
        initial_delay_seconds = 2
        period_seconds        = 5
        failure_threshold     = 10
        http_get {
          path = "/healthz"
        }
      }
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.database_url,
    google_secret_manager_secret_iam_member.jwt,
    google_secret_manager_secret_version.jwt,
  ]
}

resource "google_cloud_run_v2_service" "worker" {
  name                = "housefull-worker"
  location            = var.region
  deletion_protection = false

  # Only Google services in this project can reach it, and IAM narrows that to
  # the Pub/Sub push identity.
  ingress = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account                  = google_service_account.this["worker"].email
    max_instance_request_concurrency = 10

    scaling {
      min_instance_count = 0
      max_instance_count = local.worker_max_instances
    }

    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        subnetwork = var.subnet_id
      }
    }

    containers {
      image = var.image

      env {
        name  = "APP_MODULE"
        value = "housefull.worker:app"
      }
      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "DB_POOL_SIZE"
        value = tostring(local.worker_pool_size)
      }
      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = var.database_url_secret
            version = "latest"
          }
        }
      }
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.database_url]
}

resource "google_cloud_run_v2_service_iam_member" "pubsub_invokes_worker" {
  name     = google_cloud_run_v2_service.worker.name
  location = var.region
  role     = "roles/run.invoker"
  member   = google_service_account.this["pubsub"].member
}

resource "google_cloud_run_v2_job" "this" {
  for_each = {
    migrate      = "scripts.migrate"
    expire-holds = "scripts.expire_holds"
  }

  name                = "housefull-${each.key}"
  location            = var.region
  deletion_protection = false

  template {
    task_count = 1

    template {
      service_account = google_service_account.this["jobs"].email
      max_retries     = 1
      timeout         = "300s"

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          subnetwork = var.subnet_id
        }
      }

      containers {
        image   = var.image
        command = ["python", "-m", each.value]

        env {
          name  = "GOOGLE_CLOUD_PROJECT"
          value = var.project_id
        }
        env {
          name = "DATABASE_URL"
          value_source {
            secret_key_ref {
              secret  = var.database_url_secret
              version = "latest"
            }
          }
        }
      }
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.database_url]
}

resource "google_cloud_run_v2_job_iam_member" "scheduler_runs_expiry" {
  name     = google_cloud_run_v2_job.this["expire-holds"].name
  location = var.region
  role     = "roles/run.invoker"
  member   = google_service_account.this["scheduler"].member
}

resource "google_cloud_scheduler_job" "expire_holds" {
  name      = "housefull-expire-holds"
  region    = var.region
  schedule  = "*/5 * * * *"
  time_zone = "Asia/Kolkata"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-run.googleapis.com/v2/${google_cloud_run_v2_job.this["expire-holds"].id}:run"

    oauth_token {
      service_account_email = google_service_account.this["scheduler"].email
    }
  }

  depends_on = [google_cloud_run_v2_job_iam_member.scheduler_runs_expiry]
}

output "api_name" {
  value = google_cloud_run_v2_service.api.name
}

output "worker_url" {
  value = google_cloud_run_v2_service.worker.uri
}

output "pubsub_push_account_email" {
  value = google_service_account.this["pubsub"].email
}
