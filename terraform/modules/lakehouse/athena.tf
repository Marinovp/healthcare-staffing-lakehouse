locals {
  athena_workgroups = {
    pipeline = {
      description   = "Athena workgroup for the pipeline"
      scan_limit_gb = 10
    }

    dashboard = {
      description   = "Streamlit dashboard queries on the published marts"
      scan_limit_gb = 1
    }
  }
}


resource "aws_athena_workgroup" "this" {
  for_each = local.athena_workgroups

  name        = "${var.name_prefix}-${each.key}"
  description = each.value.description
  #   force_destroy = var.env == "dev"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    requester_pays_enabled             = false


    result_configuration {
      output_location = "s3://${aws_s3_bucket.lake.bucket}/athena-results/${each.key}/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    bytes_scanned_cutoff_per_query = each.value.scan_limit_gb * 1024 * 1024 * 1024
  }
}
