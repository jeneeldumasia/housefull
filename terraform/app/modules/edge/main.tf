variable "region" {
  type = string
}

variable "domain" {
  type = string
}

variable "subdomain" {
  type = string
}

variable "api_service_name" {
  type = string
}

variable "grafana_subdomain" {
  type = string
}

variable "grafana_service_name" {
  type = string
}

locals {
  hostname         = "${var.subdomain}.${var.domain}"
  grafana_hostname = "${var.grafana_subdomain}.${var.domain}"
}

resource "google_compute_global_address" "public" {
  name = "housefull-public"
}

resource "google_compute_region_network_endpoint_group" "api" {
  name                  = "housefull-api"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = var.api_service_name
  }
}

resource "google_compute_backend_service" "api" {
  name                  = "housefull-api"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"

  # The load balancer sets this itself, and Cloud Run only accepts traffic from
  # the load balancer, so the app can trust it for login limits.
  custom_request_headers = ["X-Client-IP: {client_ip_address}"]

  backend {
    group = google_compute_region_network_endpoint_group.api.id
  }
}

resource "google_compute_region_network_endpoint_group" "grafana" {
  name                  = "housefull-grafana"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = var.grafana_service_name
  }
}

resource "google_compute_backend_service" "grafana" {
  name                  = "housefull-grafana"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"

  backend {
    group = google_compute_region_network_endpoint_group.grafana.id
  }
}

resource "google_compute_url_map" "https" {
  name            = "housefull-https"
  default_service = google_compute_backend_service.api.id

  host_rule {
    hosts        = [local.grafana_hostname]
    path_matcher = "grafana"
  }

  path_matcher {
    name            = "grafana"
    default_service = google_compute_backend_service.grafana.id
  }
}

resource "google_compute_managed_ssl_certificate" "main" {
  name = "housefull"

  managed {
    domains = [local.hostname]
  }
}

# A separate certificate, so adding Grafana doesn't reissue the live site's.
resource "google_compute_managed_ssl_certificate" "grafana" {
  name = "housefull-grafana"

  managed {
    domains = [local.grafana_hostname]
  }
}

resource "google_compute_target_https_proxy" "main" {
  name    = "housefull"
  url_map = google_compute_url_map.https.id
  ssl_certificates = [
    google_compute_managed_ssl_certificate.main.id,
    google_compute_managed_ssl_certificate.grafana.id,
  ]
}

resource "google_compute_global_forwarding_rule" "https" {
  name                  = "housefull-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.public.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.main.id
}

resource "google_compute_url_map" "http_redirect" {
  name = "housefull-http-redirect"

  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "housefull-http-redirect"
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "housefull-http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.public.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}

data "cloudflare_zone" "main" {
  name = var.domain
}

# DNS only. A second proxy in front would complicate the certificate and hide
# the real client address.
resource "cloudflare_record" "app" {
  zone_id = data.cloudflare_zone.main.id
  name    = var.subdomain
  type    = "A"
  content = google_compute_global_address.public.address
  proxied = false
  ttl     = 300
}

resource "cloudflare_record" "grafana" {
  zone_id = data.cloudflare_zone.main.id
  name    = var.grafana_subdomain
  type    = "A"
  content = google_compute_global_address.public.address
  proxied = false
  ttl     = 300
}

output "ip_address" {
  value = google_compute_global_address.public.address
}
