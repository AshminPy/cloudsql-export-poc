variable "project_id" {
  description = "GCP project to deploy the POC into. Must be a personal/non-production project."
  type        = string
}

variable "region" {
  description = "Region for the Cloud SQL instance and GCS bucket. Kept identical for both so export traffic never leaves the region."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone for the (single-zone / zonal) Cloud SQL instance."
  type        = string
  default     = "us-central1-a"
}

variable "name_prefix" {
  description = "Prefix applied to every resource this POC creates, so it is trivially greppable and never collides with pre-existing project resources."
  type        = string
  default     = "pgexport-poc"
}

variable "db_tier" {
  description = "Cloud SQL machine tier. db-f1-micro is Google's documented shared-core tier for low-cost test/dev instances (not SLA-covered, not for production) -- exactly this POC's use case."
  type        = string
  default     = "db-f1-micro"
}

variable "postgres_version" {
  description = "Cloud SQL for PostgreSQL major version."
  type        = string
  default     = "POSTGRES_15"
}

variable "db_disk_size_gb" {
  description = "Smallest allowed Cloud SQL disk size."
  type        = number
  default     = 10
}

variable "export_bucket_retention_days" {
  description = "How many days an export object survives in the bucket before lifecycle deletion. POC default is short; production would tune this to the real retention/compliance requirement."
  type        = number
  default     = 3
}

variable "deletion_protection" {
  description = "Terraform/Cloud SQL deletion protection. Left false on purpose -- this is a throwaway POC instance that must be fully destroyable by `terraform destroy`."
  type        = bool
  default     = false
}

variable "enable_scheduler_demo" {
  description = "Whether to create the Cloud Scheduler job that demonstrates automated, unattended triggering of the offloaded export (Phase 7). Safe to disable if you only want the manual export path."
  type        = bool
  default     = true
}

variable "sqladmin_api_version" {
  description = "Cloud SQL Admin API version used by the export workflow's direct HTTP calls. Both v1 and v1beta4 are documented for instances.export/import; default v1 (the stable, non-beta path) -- override to v1beta4 only if live testing in your environment shows v1 failing."
  type        = string
  default     = "v1"
}

variable "scheduler_cron" {
  description = "Cron schedule for the demo export job. Default: 02:00 daily, matching a typical off-peak backup window."
  type        = string
  default     = "0 2 * * *"
}

variable "manage_sql_instance" {
  description = "true (default): Terraform creates a new POC Cloud SQL instance (the path this repo was built and tested against). false: reuse an EXISTING Cloud SQL instance instead -- set existing_instance_name and existing_database_name below, and Terraform will only manage the export bucket, IAM, and scheduler around it. Use false when adapting this repo to a real database (see README 'How to adapt this code')."
  type        = bool
  default     = true
}

variable "existing_instance_name" {
  description = "Only used when manage_sql_instance = false. The name of your existing Cloud SQL instance (not the connection name -- just the instance ID, e.g. 'prod-postgres')."
  type        = string
  default     = ""
}

variable "existing_database_name" {
  description = "Only used when manage_sql_instance = false. The database inside your existing instance to export/import against."
  type        = string
  default     = ""
}

variable "db_name" {
  description = "Database name. Only used when manage_sql_instance = true (a new instance is being created)."
  type        = string
  default     = "poc_db"
}

variable "db_app_user" {
  description = "Database user Terraform creates. Only used when manage_sql_instance = true."
  type        = string
  default     = "poc_app"
}

variable "labels" {
  description = "Labels applied to every resource that supports them, for cost attribution and easy identification/cleanup."
  type        = map(string)
  default = {
    project  = "cloudsql-export-poc"
    purpose  = "poc"
    teardown = "true"
  }
}
