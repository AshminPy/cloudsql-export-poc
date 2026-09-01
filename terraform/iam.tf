# The identity that actually calls the Cloud SQL Admin API is the WORKFLOW's own
# service account (workflow_runner, defined in workflow.tf) -- not Cloud Scheduler's
# identity. Scheduler only invokes the workflow (roles/workflows.invoker on that one
# workflow, see workflow.tf); it has zero Cloud SQL or GCS permissions of its own.
# This keeps "trigger the automation" and "talk to Cloud SQL" as genuinely separate
# identities, matching the same separation-of-duties pattern the GCS bucket IAM in
# storage.tf already uses for the Cloud SQL service agent.
#
# Split into two roles/bindings on purpose. Cloud SQL IS a supported service for IAM
# Conditions (resource.type "sqladmin.googleapis.com/Instance", resource.name format
# "projects/<id>/instances/<instance-id>" -- verified against
# cloud.google.com/iam/docs/conditions-resource-attributes), so the two permissions
# that check against an Instance resource (export, get) CAN be scoped to this one POC
# instance. cloudsql.operations.get checks against an Operation resource, and Cloud SQL
# only supports IAM Conditions on Instance and BackupRun resource types -- no Operation
# support exists, so that one permission has no way to be scoped narrower than the
# project. That's a genuine platform limit, not a shortcut: it's the smallest role that
# can express "check on an export operation's status."

resource "google_project_iam_custom_role" "export_trigger" {
  count       = var.enable_scheduler_demo ? 1 : 0
  project     = var.project_id
  role_id     = replace("${var.name_prefix}_export_trigger", "-", "_")
  title       = "Cloud SQL export trigger"
  description = "Start and inspect a Cloud SQL export -- conditioned to one instance below."
  permissions = [
    "cloudsql.instances.export",
    "cloudsql.instances.get",
  ]
}

resource "google_project_iam_member" "workflow_runner_export_binding" {
  count   = var.enable_scheduler_demo ? 1 : 0
  project = var.project_id
  role    = google_project_iam_custom_role.export_trigger[0].id
  member  = "serviceAccount:${google_service_account.workflow_runner[0].email}"

  condition {
    title       = "restrict-export-to-poc-instance"
    description = "Only allow export/get against this POC's own Cloud SQL instance, not any other instance in the project."
    expression  = "resource.type != 'sqladmin.googleapis.com/Instance' || resource.name == 'projects/${var.project_id}/instances/${local.instance_name}'"
  }
}

resource "google_project_iam_custom_role" "export_operation_reader" {
  count       = var.enable_scheduler_demo ? 1 : 0
  project     = var.project_id
  role_id     = replace("${var.name_prefix}_export_op_reader", "-", "_")
  title       = "Cloud SQL export operation reader"
  description = "cloudsql.operations.get only. Project-wide because Cloud SQL IAM Conditions do not support the Operation resource type (only Instance and BackupRun) -- documented platform limit, not a scoping shortcut."
  permissions = [
    "cloudsql.operations.get",
  ]
}

resource "google_project_iam_member" "workflow_runner_operation_reader_binding" {
  count   = var.enable_scheduler_demo ? 1 : 0
  project = var.project_id
  role    = google_project_iam_custom_role.export_operation_reader[0].id
  member  = "serviceAccount:${google_service_account.workflow_runner[0].email}"
}
