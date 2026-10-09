variable "name_prefix" {
  description = "Prefix for naming resources"
  type        = string
}

variable "catalog_prefix" {
  description = "Prefix of the Glue databases, filled into the SQL as $${prefix}"
  type        = string
}

variable "lake_bucket_name" {
  description = "Data lake bucket the build reads and writes"
  type        = string
}

variable "athena_workgroup_name" {
  description = "Athena workgroup the build queries run in"
  type        = string
}

variable "glue_job_name" {
  description = "Name of the drive_sync Glue job"
  type        = string
}

variable "manifest_table_name" {
  description = "DynamoDB ingest manifest table"
  type        = string
}

variable "alert_email" {
  description = "Email address that receives pipeline failure alerts"
  type        = string
}
