terraform {
  required_version = ">= 1.7"

  cloud {
    organization = "Housefull"
    workspaces {
      name = "housefull-app"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Reads CLOUDFLARE_API_TOKEN from the environment.
provider "cloudflare" {}
