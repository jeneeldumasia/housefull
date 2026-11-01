variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "network_id" {
  type = string
}

locals {
  grafana = "${path.root}/../../monitoring/grafana"
  # Google's published range for IAP tunnels.
  iap_range = "35.235.240.0/20"
}

resource "google_project_service" "iap" {
  service            = "iap.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_subnetwork" "vpn" {
  name          = "housefull-vpn"
  region        = var.region
  network       = var.network_id
  ip_cidr_range = "10.10.1.0/24"
}

resource "google_compute_address" "vpn" {
  name   = "housefull-vpn"
  region = var.region
}

resource "google_service_account" "vpn" {
  account_id = "housefull-vpn"
}

resource "google_project_iam_member" "vpn" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.viewer"])

  project = var.project_id
  role    = each.value
  member  = google_service_account.vpn.member
}

# The only thing open to the internet is the WireGuard port.
resource "google_compute_firewall" "wireguard" {
  name          = "housefull-wireguard"
  network       = var.network_id
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["housefull-vpn"]

  allow {
    protocol = "udp"
    ports    = ["53230"]
  }
}

# SSH and device enrolment only arrive through Google's identity-checked tunnel.
resource "google_compute_firewall" "iap" {
  name          = "housefull-iap"
  network       = var.network_id
  source_ranges = [local.iap_range]
  target_tags   = ["housefull-vpn"]

  allow {
    protocol = "tcp"
    ports    = ["22", "8081"]
  }
}

resource "google_compute_instance" "vpn" {
  name         = "housefull-vpn"
  zone         = "${var.region}-a"
  machine_type = "e2-micro"
  tags         = ["housefull-vpn"]

  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 15
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.vpn.id

    access_config {
      nat_ip = google_compute_address.vpn.address
    }
  }

  service_account {
    email  = google_service_account.vpn.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  metadata = {
    enable-oslogin     = "TRUE"
    project            = var.project_id
    wag-config         = file("${path.module}/wag-config.json")
    grafana-datasource = file("${local.grafana}/provisioning/datasources/monitoring.yaml")
    grafana-provider   = file("${local.grafana}/provisioning/dashboards/housefull.yaml")
    grafana-dashboard  = replace(file("${local.grafana}/dashboards/housefull.json"), "__PROJECT__", var.project_id)
  }

  metadata_startup_script = file("${path.module}/startup.sh")

  depends_on = [google_project_iam_member.vpn]
}

output "ip_address" {
  value = google_compute_address.vpn.address
}
