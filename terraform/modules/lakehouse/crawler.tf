# ---------- IAM role the crawler runs as ----------

data "aws_iam_policy_document" "crawler_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "crawler" {
  name               = "${var.name_prefix}-raw-crawler"
  assume_role_policy = data.aws_iam_policy_document.crawler_trust.json
}

resource "aws_iam_role_policy_attachment" "crawler_glue_service" {
  role       = aws_iam_role.crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "crawler_read_raw" {
  statement {
    sid       = "ListRawPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.lake.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["raw/*"]
    }
  }

  statement {
    sid       = "ReadRawObjects"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.lake.arn}/raw/*"]
  }
}

resource "aws_iam_role_policy" "crawler_read_raw" {
  name   = "read-raw"
  role   = aws_iam_role.crawler.id
  policy = data.aws_iam_policy_document.crawler_read_raw.json
}

# ---------- Classifier: every column as text, header row present ----------

resource "aws_glue_classifier" "csv_all_strings" {
  name = "${var.name_prefix}-csv-all-strings"

  csv_classifier {
    contains_header            = "PRESENT"
    delimiter                  = ","
    quote_symbol               = "\""
    custom_datatype_configured = true
    custom_datatypes           = ["STRING"]
  }
}

# ---------- Crawler: one table per dataset folder under raw/ ----------

resource "aws_glue_crawler" "raw" {
  name          = "${var.name_prefix}-raw"
  role          = aws_iam_role.crawler.arn
  database_name = aws_glue_catalog_database.this["raw"].name
  classifiers   = [aws_glue_classifier.csv_all_strings.name]

  s3_target {
    path = "s3://${aws_s3_bucket.lake.bucket}/raw/"
  }

  configuration = jsonencode({
    Version = 1.0
    Grouping = {
      TableLevelConfiguration = 3
    }
  })

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }
}
