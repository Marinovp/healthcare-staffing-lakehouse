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
