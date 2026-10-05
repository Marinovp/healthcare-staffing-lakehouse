data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  lake_bucket_name = "${var.name_prefix}-lake-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
}
