variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-west-2"
}

variable "account_id" {
  description = "The only AWS account this stack may run against"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12 digit AWS account ID"
  }
}

variable "alert_email" {
  description = "The email address to send alerts to."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "drive_folder_id" {
  description = "ID of the Google Drive folder holding the source files (the last part of its URL)"
  type        = string
}
