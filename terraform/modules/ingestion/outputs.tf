output "google_secret_name" {
  description = "The name of the Google Drive service account secret"
  value       = aws_secretsmanager_secret.google_service_account.name
}

output "dynamodb_manifest_table_name" {
  description = "The name of the DynamoDB table used for the ingestion manifest"
  value       = aws_dynamodb_table.manifest.name
}

output "drive_sync_job_name" {
  description = "Name of the Glue job that copies Drive files to raw"
  value       = aws_glue_job.drive_sync.name
}
