# The Google service-account key (JSON) used by drive_sync to read the Drive folder.
# Terraform creates the empty secret only. Its value is set outside Terraform
# (aws secretsmanager put-secret-value), so the key never enters Terraform state.

resource "aws_secretsmanager_secret" "google_service_account" {
  name                    = "${var.name_prefix}/google-drive-service-account"
  description             = "Google Drive service account secret for reading Healtcare_Metrics Drive folder"
  recovery_window_in_days = 7
}
