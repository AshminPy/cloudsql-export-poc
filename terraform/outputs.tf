output "instance_name" {
  value = local.instance_name
}

output "instance_connection_name" {
  value = local.instance_connection_name
}

output "database_name" {
  value = local.database_name
}

output "app_db_user" {
  value = var.manage_sql_instance ? google_sql_user.app[0].name : null
}

output "app_db_password" {
  value       = var.manage_sql_instance ? random_password.pg_app_password[0].result : null
  sensitive   = true
  description = "null when manage_sql_instance = false -- reusing an existing instance means Terraform never touches its credentials."
}

output "export_bucket" {
  value = google_storage_bucket.export_bucket.name
}

output "cloudsql_instance_service_account" {
  value = local.instance_service_account
}

output "downloader_service_account_email" {
  value = google_service_account.downloader.email
}

output "scheduler_job_name" {
  value = var.enable_scheduler_demo ? google_cloud_scheduler_job.export_job[0].name : null
}

output "scheduler_trigger_sa_email" {
  value = var.enable_scheduler_demo ? google_service_account.scheduler_trigger[0].email : null
}

output "workflow_name" {
  value = var.enable_scheduler_demo ? google_workflows_workflow.export_workflow[0].name : null
}

output "workflow_runner_sa_email" {
  value = var.enable_scheduler_demo ? google_service_account.workflow_runner[0].email : null
}
