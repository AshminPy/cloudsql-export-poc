# Smallest practical Cloud SQL for PostgreSQL instance: db-f1-micro is Google's own
# documented "low-cost test and development" shared-core tier (not SLA-covered, not
# for production -- which is exactly right for a POC that lives for a few hours).
# Zonal (not Regional/HA) -- HA doubles compute cost and buys nothing for a throwaway
# test instance.
#
# Network exposure: ipv4_enabled = true (Cloud SQL requires either a public IP or a
# private IP + VPC; provisioning a VPC + Private Service Access connection is real,
# permanent-ish infrastructure this POC doesn't need, since NOTHING in this workflow
# ever opens a direct SQL connection to the instance -- seeding and restoring both go
# through the Cloud SQL Admin API + GCS, never through the Postgres wire protocol).
# authorized_networks is deliberately empty, so the instance's firewall accepts
# connections from nowhere -- the public IP exists but nothing can reach it. A real
# production deployment should use Private IP (see README "Production recommendations").
#
# Reusability: set var.manage_sql_instance = false to point this whole stack at an
# EXISTING Cloud SQL instance instead (var.existing_instance_name /
# var.existing_database_name) -- everything downstream (storage.tf, iam.tf,
# scheduler.tf) reads from local.instance_name / local.instance_service_account /
# local.database_name below, not directly from this resource, so nothing else needs to
# change. See README "Deployment instructions" for both paths.

resource "google_sql_database_instance" "poc" {
  count               = var.manage_sql_instance ? 1 : 0
  provider            = google-beta
  name                = "${var.name_prefix}-pg"
  project             = var.project_id
  region              = var.region
  database_version    = var.postgres_version
  deletion_protection = var.deletion_protection

  depends_on = [google_project_service.sqladmin]

  settings {
    tier              = var.db_tier
    availability_type = "ZONAL"
    disk_size         = var.db_disk_size_gb
    disk_autoresize   = false
    disk_type         = "PD_SSD"

    backup_configuration {
      enabled = false # POC instance is destroyed same-day; no backup value, avoids extra storage cost
    }

    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
      # No authorized_networks blocks at all = zero allowed source ranges = the
      # instance's public IP exists but rejects every inbound connection attempt.
    }

    location_preference {
      zone = var.zone
    }

    user_labels = var.labels
  }
}

resource "random_password" "pg_app_password" {
  count   = var.manage_sql_instance ? 1 : 0
  length  = 24
  special = false # keep it shell/URI-safe for local restore-validation steps
}

resource "google_sql_user" "app" {
  count    = var.manage_sql_instance ? 1 : 0
  provider = google-beta
  project  = var.project_id
  instance = google_sql_database_instance.poc[0].name
  name     = var.db_app_user
  password = random_password.pg_app_password[0].result
}

resource "google_sql_database" "poc_db" {
  count    = var.manage_sql_instance ? 1 : 0
  provider = google-beta
  project  = var.project_id
  instance = google_sql_database_instance.poc[0].name
  name     = var.db_name
}

# Looked up (never created/modified) when reusing an existing instance -- read-only,
# so pointing this at a real production instance can never accidentally change it.
data "google_sql_database_instance" "existing" {
  count    = var.manage_sql_instance ? 0 : 1
  provider = google-beta
  project  = var.project_id
  name     = var.existing_instance_name
}

locals {
  instance_name = var.manage_sql_instance ? google_sql_database_instance.poc[0].name : data.google_sql_database_instance.existing[0].name

  instance_service_account = var.manage_sql_instance ? google_sql_database_instance.poc[0].service_account_email_address : data.google_sql_database_instance.existing[0].service_account_email_address

  instance_connection_name = var.manage_sql_instance ? google_sql_database_instance.poc[0].connection_name : data.google_sql_database_instance.existing[0].connection_name

  database_name = var.manage_sql_instance ? var.db_name : var.existing_database_name
}
