variable "region" {
  type = string
}

resource "google_compute_network" "main" {
  name                    = "housefull"
  auto_create_subnetworks = false
}

# Cloud Run instances get addresses from here to reach the database.
resource "google_compute_subnetwork" "services" {
  name                     = "housefull-services"
  region                   = var.region
  network                  = google_compute_network.main.id
  ip_cidr_range            = "10.10.0.0/24"
  private_ip_google_access = true
}

# Google runs Cloud SQL in its own network. This reserves a range for it and
# peers the two, which is what gives the database a private address.
resource "google_compute_global_address" "database_range" {
  name          = "housefull-database"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "database" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.database_range.name]
  deletion_policy         = "ABANDON"
}

output "network_id" {
  value = google_compute_network.main.id
  # The database must wait for the peering, not just the network.
  depends_on = [google_service_networking_connection.database]
}

output "subnet_id" {
  value = google_compute_subnetwork.services.id
}
