resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "housefull"
  format        = "DOCKER"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-old"
    action = "DELETE"
    condition {
      older_than = "2592000s"
    }
  }
}

module "network" {
  source = "./modules/network"

  region = var.region
}

module "database" {
  source = "./modules/database"

  region     = var.region
  tier       = var.database_tier
  network_id = module.network.network_id

  depends_on = [module.network]
}

module "messaging" {
  source = "./modules/messaging"

  project_id   = var.project_id
  topic_id     = module.messaging_topic.topic_id
  push_url     = "${module.services.worker_url}/pubsub/push"
  push_account = module.services.pubsub_push_account_email
}

module "services" {
  source = "./modules/services"

  project_id          = var.project_id
  region              = var.region
  image               = var.image
  subnet_id           = module.network.subnet_id
  database_url_secret = module.database.url_secret_id
  bookings_topic_id   = module.messaging_topic.topic_id
  bookings_topic_name = module.messaging_topic.topic_name
}

module "messaging_topic" {
  source = "./modules/messaging/topic"
}

module "edge" {
  source = "./modules/edge"

  region           = var.region
  domain           = var.domain
  subdomain        = var.subdomain
  api_service_name = module.services.api_name
}

module "monitoring" {
  source = "./modules/monitoring"

  alert_email = var.alert_email
  hostname    = "${var.subdomain}.${var.domain}"
}

module "vpn" {
  source = "./modules/vpn"

  project_id = var.project_id
  region     = var.region
  network_id = module.network.network_id
}
