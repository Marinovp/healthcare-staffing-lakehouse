variable "env" {
  description = "The environment for the lakehouse deployment (e.g., dev, prod)."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.env)
    error_message = "The 'env' variable must be one of the following: 'dev' or 'prod'."
  }
}

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


variable "monthly_budget_usd" {
  description = "The monthly budget in USD for the lakehouse deployment."
  type        = number
  default     = 10

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be a positive number."
  }
}
