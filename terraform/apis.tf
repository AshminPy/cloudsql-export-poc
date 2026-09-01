# Only the APIs this POC actually needs. storage.googleapis.com, iam.googleapis.com,
# serviceusage.googleapis.com and cloudresourcemanager.googleapis.com are commonly
# already enabled by other work in a shared project before this POC runs -- they are
# deliberately NOT declared here, so `terraform destroy` can never disable an API
# something else in the project depends on. If you're deploying into a brand-new
# project, `terraform apply` will fail on those (Cloud SQL/Storage/IAM calls needing
# an API that isn't enabled) -- enable them once, manually, up front.
#
# disable_on_destroy = false on the APIs we DO enable: disabling a project-level API is
# a shared, blast-radius-beyond-this-POC action. Leaving it enabled after destroy costs
# nothing (API enablement itself is free) and is the safer default for a personal
# project that also runs other services.

resource "google_project_service" "sqladmin" {
  project            = var.project_id
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudscheduler" {
  count              = var.enable_scheduler_demo ? 1 : 0
  project            = var.project_id
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
}

# NOTE: an earlier version of this file also created a google_project_service_identity
# here, on the assumption that Cloud SQL's export/import identity was the generic
# per-API service agent. It is not -- see storage.tf's comment on
# google_storage_bucket_iam_member.cloudsql_sa_export_access for what the real identity
# is and how that was discovered. Removed because it granted IAM to an identity that
# never actually performs the export/import call.
