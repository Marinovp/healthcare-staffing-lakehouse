locals {
  # Glue database per medallion layer (key = layer, value = description)
  catalog_databases = {
    raw        = "Bronze: tables over the original CSV files in raw/"
    staging    = "Validation views (base_) that build silver"
    builds     = "Each run's silver and gold Iceberg tables"
    silver     = "Published silver: valid rows of each dataset"
    quarantine = "Published rejected rows, with the reason"
    marts      = "Published gold: star schema and metrics for the dashboard"
    audit      = "Data-check results for every run"
  }
}

resource "aws_glue_catalog_database" "this" {
  for_each = local.catalog_databases

  name        = "${var.catalog_prefix}_${each.key}"
  description = each.value
}
