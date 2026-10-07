# One item per Drive file: drive_file_id (key), name, md5, modified_time, s3_key,
# status (LANDED or PROCESSED) and landed_at. Only the key is declared; DynamoDB
# doesn't need the other attributes defined in advance.

resource "aws_dynamodb_table" "manifest" {
  name                        = "${var.name_prefix}-ingest-manifest"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "drive_file_id"
  deletion_protection_enabled = true

  attribute {
    name = "drive_file_id"
    type = "S"
  }
  point_in_time_recovery {
    enabled = true
  }

}
