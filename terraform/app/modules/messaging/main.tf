variable "project_id" {
  type = string
}

variable "push_url" {
  type = string
}

variable "push_account" {
  type = string
}

variable "topic_id" {
  type = string
}

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  pubsub_agent = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic" "dead_letter" {
  name = "bookings-dead-letter"
}

# Keeps failed messages for inspection. A topic with no subscription drops them.
resource "google_pubsub_subscription" "dead_letter" {
  name                       = "bookings-dead-letter"
  topic                      = google_pubsub_topic.dead_letter.id
  message_retention_duration = "604800s"

  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_subscription" "worker" {
  name                 = "bookings-worker"
  topic                = var.topic_id
  ack_deadline_seconds = 30

  push_config {
    push_endpoint = var.push_url

    oidc_token {
      service_account_email = var.push_account
      audience              = var.push_url
    }
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [
    google_pubsub_topic_iam_member.agent_publishes_dead_letters,
  ]
}

# Pub/Sub's own agent moves messages, so it needs both of these.
resource "google_pubsub_topic_iam_member" "agent_publishes_dead_letters" {
  topic  = google_pubsub_topic.dead_letter.id
  role   = "roles/pubsub.publisher"
  member = local.pubsub_agent
}

resource "google_pubsub_subscription_iam_member" "agent_reads_worker_subscription" {
  subscription = google_pubsub_subscription.worker.id
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}
