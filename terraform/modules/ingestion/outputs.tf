output "google_secret_name" {
  description = "The name of the Google Drive service account secret"
  value       = aws_secretsmanager_secret.google_service_account.name
}
