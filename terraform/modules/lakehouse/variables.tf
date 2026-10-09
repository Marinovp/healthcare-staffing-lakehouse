variable "name_prefix" {
  description = "The prefix for naming resources in the lakehouse deployment."
  type        = string
}

variable "catalog_prefix" {
  description = "The prefix for Glue DB and Athena names (lower case, digits and underscores only)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]*$", var.catalog_prefix))
    error_message = "catalog_prefix must start with a lowercase letter and contain only lowercase letters, digits and underscores."
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
