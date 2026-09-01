# Smallest managed orchestration that satisfies both real requirements a plain Cloud
# Scheduler HTTP target cannot: a dynamic, timestamped export filename (Scheduler's
# job body is static JSON, fixed at terraform-apply time) and tracking the export
# operation through to completion instead of guessing a fixed wait. Cloud Workflows is
# serverless and billed per-step, not a standing service -- no Cloud Run, no Cloud
# Functions, no Pub/Sub needed for this.

resource "google_project_service" "workflows" {
  count              = var.enable_scheduler_demo ? 1 : 0
  project            = var.project_id
  service            = "workflows.googleapis.com"
  disable_on_destroy = false
}

# Dedicated identity the WORKFLOW itself runs as -- separate from the Scheduler's own
# identity below. This is the one that actually calls the Cloud SQL Admin API, so it
# is the one that needs cloudsql.instances.export/get (conditioned to this one
# instance) and cloudsql.operations.get (project-wide -- see iam.tf's comment on why
# that one permission can't be scoped narrower).
resource "google_service_account" "workflow_runner" {
  count        = var.enable_scheduler_demo ? 1 : 0
  project      = var.project_id
  account_id   = "${var.name_prefix}-workflow-runner"
  display_name = "Runs the scheduled export workflow (Cloud SQL export/operations only)"
}

resource "google_workflows_workflow" "export_workflow" {
  count           = var.enable_scheduler_demo ? 1 : 0
  project         = var.project_id
  region          = var.region
  name            = "${var.name_prefix}-export-workflow"
  description     = "Starts an offloaded Cloud SQL export to a timestamped GCS object and waits for it to finish."
  service_account = google_service_account.workflow_runner[0].id

  source_contents = templatefile("${path.module}/export-workflow.yaml.tftpl", {
    sqladmin_api_version = var.sqladmin_api_version
  })

  depends_on = [google_project_service.workflows]
}

# Cloud Scheduler's own identity: can invoke this one workflow, nothing else. It never
# talks to Cloud SQL directly any more -- that happens inside the workflow, under a
# different identity.
resource "google_service_account" "scheduler_trigger" {
  count        = var.enable_scheduler_demo ? 1 : 0
  project      = var.project_id
  account_id   = "${var.name_prefix}-scheduler-trigger"
  display_name = "Invokes the export workflow on a schedule (workflows.invoker, no Cloud SQL/GCS access)"
}

# roles/workflows.invoker, project-wide -- verified live (`gcloud workflows
# add-iam-policy-binding` does not exist; neither the google nor google-beta Terraform
# provider has a per-workflow IAM resource) that Cloud Workflows has no per-resource
# IAM binding today, unlike Cloud SQL's Instance-scoped conditions used elsewhere in
# this repo. Same category of genuine platform limit as export_operation_reader above
# -- this SA can invoke any workflow in the project, but has no other permission at all
# (no Cloud SQL access, no GCS access), which bounds the actual blast radius.
resource "google_project_iam_member" "scheduler_can_invoke_workflows" {
  count   = var.enable_scheduler_demo ? 1 : 0
  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.scheduler_trigger[0].email}"
}

resource "google_cloud_scheduler_job" "export_job" {
  count       = var.enable_scheduler_demo ? 1 : 0
  project     = var.project_id
  region      = var.region
  name        = "${var.name_prefix}-scheduled-export"
  description = "Triggers the offloaded Cloud SQL export workflow on a schedule."
  schedule    = var.scheduler_cron
  time_zone   = "Etc/UTC"

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/${google_workflows_workflow.export_workflow[0].id}/executions"

    headers = {
      "Content-Type" = "application/json"
    }

    body = base64encode(jsonencode({
      argument = jsonencode({
        project_id    = var.project_id
        instance_name = local.instance_name
        database_name = local.database_name
        bucket        = google_storage_bucket.export_bucket.name
      })
    }))

    oauth_token {
      service_account_email = google_service_account.scheduler_trigger[0].email
    }
  }
}
