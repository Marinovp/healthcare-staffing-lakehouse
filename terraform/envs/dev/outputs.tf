output "name_prefix" {
  description = "AWS resources name prefix"
  value       = local.name_prefix
}

output "catalog_prefix" {
  description = "Glue Catalog prefix and Athena database name prefix"
  value       = local.catalog_prefix
}
