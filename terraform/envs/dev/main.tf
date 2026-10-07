locals {
  env = "dev"

  # Most aws resource names allow hyphens: hsl-dev
  name_prefix = "hsl-${local.env}"

  # Glue databases and Athena names should use underscores: hsl_dev_...
  catalog_prefix = "hsl_${local.env}"
}

module "lakehouse" {
  source = "../../modules/lakehouse"

  env            = local.env
  name_prefix    = local.name_prefix
  catalog_prefix = local.catalog_prefix
  alert_email    = var.alert_email
}

module "ingestion" {
  source = "../../modules/ingestion"

  name_prefix = local.name_prefix
}
