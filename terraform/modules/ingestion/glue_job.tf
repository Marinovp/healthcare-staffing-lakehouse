data "aws_region" "current" {}

locals {
  job_dir         = "${path.module}/../../../glue/drive_sync"
  lake_bucket_arn = "arn:aws:s3:::${var.lake_bucket_name}"

  # Same pinned versions as local runs.
  python_modules = join(",", compact([
    for line in split("\n", file("${local.job_dir}/requirements.txt")) : trimspace(line)
  ]))
}

# ---------- IAM role ----------

data "aws_iam_policy_document" "glue_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "drive_sync" {
  name               = "${var.name_prefix}-drive-sync"
  assume_role_policy = data.aws_iam_policy_document.glue_trust.json
}

resource "aws_iam_role_policy_attachment" "drive_sync_glue_service" {
  role       = aws_iam_role.drive_sync.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "drive_sync" {
  statement {
    sid       = "ReadJobScript"
    actions   = ["s3:GetObject"]
    resources = ["${local.lake_bucket_arn}/glue-scripts/*"]
  }

  statement {
    sid       = "WriteRawFiles"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${local.lake_bucket_arn}/raw/*"]
  }

  statement {
    sid       = "ReadGoogleKey"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.google_service_account.arn]
  }

  statement {
    sid       = "ReadWriteManifest"
    actions   = ["dynamodb:Scan", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.manifest.arn]
  }
}

resource "aws_iam_role_policy" "drive_sync" {
  name   = "drive-sync"
  role   = aws_iam_role.drive_sync.id
  policy = data.aws_iam_policy_document.drive_sync.json
}

# ---------- Script and job ----------

resource "aws_s3_object" "drive_sync_script" {
  bucket = var.lake_bucket_name
  key    = "glue-scripts/drive_sync.py"
  source = "${local.job_dir}/drive_sync.py"
  etag   = filemd5("${local.job_dir}/drive_sync.py")
}

resource "aws_glue_job" "drive_sync" {
  name         = "${var.name_prefix}-drive-sync"
  role_arn     = aws_iam_role.drive_sync.arn
  max_capacity = 0.0625
  timeout      = 60
  max_retries  = 1

  command {
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "s3://${var.lake_bucket_name}/${aws_s3_object.drive_sync_script.key}"
  }

  execution_property {
    max_concurrent_runs = 1
  }

  default_arguments = {
    "library-set"                 = "analytics"
    "--additional-python-modules" = local.python_modules
    "--folder_id"                 = var.drive_folder_id
    "--bucket"                    = var.lake_bucket_name
    "--manifest_table"            = aws_dynamodb_table.manifest.name
    "--secret_name"               = aws_secretsmanager_secret.google_service_account.name
    "--raw_database"              = var.raw_database_name
    "--region"                    = data.aws_region.current.region
  }
}
