variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "github_repository_id" {
  description = "Numeric GitHub repo ID. Unlike a name, it can't be reused."
  type        = string
  default     = "1441963170"
}
