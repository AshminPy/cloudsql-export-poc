# Regional bucket, co-located with the Cloud SQL instance's region so export traffic
# never crosses regions. uniform_bucket_level_access + no public access: this bucket
# only ever needs to be reachable by (a) the Cloud SQL service agent, writing exports,
# and (b) whoever/whatever downloads the dump (your user account or the dedicated
# downloader service account below) -- never the public internet.

resource "random_id" "bucket_suffix" {
  byte_length = 3
}

resource "google_storage_bucket" "export_bucket" {
  name     = "${var.name_prefix}-export-${random_id.bucket_suffix.hex}"
  project  = var.project_id
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true # POC bucket must be destroyable even if it still holds an export object

  lifecycle_rule {
    condition {
      age = var.export_bucket_retention_days
    }
    action {
      type = "Delete"
    }
  }

  labels = var.labels
}

# Least-privilege grant: the Cloud SQL service agent gets create/get/list/delete on
# THIS bucket only (via a custom role), not project-wide storage.objectAdmin and not
# access to any other bucket in the project. This is what Google's own docs require
# for both offloaded export and import:
# https://docs.cloud.google.com/sql/docs/postgres/import-export/import-export-sql
#
# IMPORTANT (found the hard way, live-verified during this POC): the identity that
# actually performs export/import is NOT the generic per-API service agent that
# google_project_service_identity creates (service-<project_number>@gcp-sa-cloud-
# sql.iam.gserviceaccount.com). Each Cloud SQL INSTANCE gets its own uniquely-suffixed
# service account (p<project_number>-<random>@gcp-sa-cloud-sql.iam.gserviceaccount.com),
# exposed by the provider as google_sql_database_instance.poc.service_account_email_
# address. Granting the generic identity (this POC's first attempt) produces exactly
# the same generic-looking error ("HTTPError 412: The service account does not have
# the required permissions for the bucket") as an actual missing-permission bug would
# -- there is no distinguishing error message, which is why this took real
# investigation (region match, role definition, and a roles/storage.objectAdmin
# diagnostic all checked out fine) before checking `gcloud sql instances describe
# --format="value(serviceAccountEmailAddress)"` and finding the mismatch. See
# README "Known limitations" for the write-up.
resource "google_project_iam_custom_role" "cloudsql_export_writer" {
  project     = var.project_id
  role_id     = replace("${var.name_prefix}_cloudsql_export_writer", "-", "_")
  title       = "Cloud SQL export/import bucket writer (POC)"
  description = "Minimum permissions the Cloud SQL service agent needs to export to / import from the POC's GCS bucket."
  permissions = [
    "storage.objects.create",
    "storage.objects.get",
    "storage.objects.list",
    "storage.objects.delete",
  ]
}

resource "google_storage_bucket_iam_member" "cloudsql_sa_export_access" {
  bucket = google_storage_bucket.export_bucket.name
  role   = google_project_iam_custom_role.cloudsql_export_writer.id
  member = "serviceAccount:${local.instance_service_account}"
}

# Dedicated downloader identity: represents the on-prem host in Phase 5/7. Read-only,
# scoped to this bucket only -- it can never write, delete, or touch any other bucket.
resource "google_service_account" "downloader" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-downloader"
  display_name = "POC on-prem download simulator (read-only, this bucket only)"
}

resource "google_storage_bucket_iam_member" "downloader_read_access" {
  bucket = google_storage_bucket.export_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.downloader.email}"
}

# Deliberately NOT creating a google_service_account_key here: short-lived credentials
# beat a long-lived static key. This service account and its bucket-scoped IAM binding
# exist to show the right identity/permission shape for "the on-prem host" -- but in
# production it should authenticate via Workload Identity Federation (an external IdP,
# e.g. the org's OIDC/SAML provider or a self-hosted STS, exchanged for a short-lived
# GCP access token), not a downloaded key file. This repo does not wire up a real WIF
# pool/provider, since that requires an actual external IdP to federate against -- see
# README "Future on-prem automation" for how to add it once one exists. Today's manual
# download instead uses the operator's own already-authenticated `gcloud` session,
# which is what someone doing this by hand would use anyway.
