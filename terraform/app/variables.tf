variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Region for everything regional."
  type        = string
  default     = "asia-south1"
}

variable "domain" {
  description = "Cloudflare zone."
  type        = string
  default     = "jeneeldumasia.dev"
}

variable "subdomain" {
  description = "Name under the zone."
  type        = string
  default     = "housefull"
}

variable "grafana_subdomain" {
  description = "Name under the zone for the public dashboard."
  type        = string
  default     = "grafana"
}

variable "image" {
  description = "Container image to run. CI passes the image built for the commit."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "database_tier" {
  description = "Cloud SQL machine size."
  type        = string
  default     = "db-f1-micro"
}

variable "alert_email" {
  description = "Where alerts are sent."
  type        = string
  sensitive   = true
}
