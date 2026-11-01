variable "region" {
  type = string
}

variable "tier" {
  type = string
}

variable "network_id" {
  type = string
}

resource "random_id" "suffix" {
  byte_length = 3
}

# Instance names can't be reused for about a week, and the app is torn down
# between demos, so each one gets a new name.
resource "google_sql_database_instance" "main" {
  name                = "housefull-${random_id.suffix.hex}"
  region              = var.region
  database_version    = "POSTGRES_16"
  deletion_protection = false

  settings {
    tier              = var.tier
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"
    disk_size         = 10
    disk_autoresize   = false

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled = false
    }
  }
}

resource "google_sql_database" "app" {
  name     = "housefull"
  instance = google_sql_database_instance.main.name
}

resource "random_password" "app" {
  length  = 32
  special = false
}

resource "google_sql_user" "app" {
  name     = "housefull"
  instance = google_sql_database_instance.main.name
  password = random_password.app.result
}

resource "google_secret_manager_secret" "url" {
  secret_id = "housefull-database-url"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "url" {
  secret      = google_secret_manager_secret.url.id
  secret_data = "postgresql://${google_sql_user.app.name}:${random_password.app.result}@${google_sql_database_instance.main.private_ip_address}:5432/${google_sql_database.app.name}?sslmode=require"
}

output "url_secret_id" {
  value      = google_secret_manager_secret.url.secret_id
  depends_on = [google_secret_manager_secret_version.url]
}
