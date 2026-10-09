# ---------- IAM role ----------

data "aws_iam_policy_document" "states_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "${var.name_prefix}-pipeline"
  assume_role_policy = data.aws_iam_policy_document.states_trust.json
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid       = "RunCopyJob"
    actions   = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns", "glue:BatchStopJobRun"]
    resources = ["arn:aws:glue:${local.region}:${local.account_id}:job/${var.glue_job_name}"]
  }

  statement {
    sid       = "RunAthenaQueries"
    actions   = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults", "athena:StopQueryExecution", "athena:GetWorkGroup"]
    resources = ["arn:aws:athena:${local.region}:${local.account_id}:workgroup/${var.athena_workgroup_name}"]
  }

  # Athena uses the caller's permissions on the catalog to read bronze and create views and tables.
  statement {
    sid = "UseProjectCatalog"
    actions = [
      "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables",
      "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
      "glue:CreateTable", "glue:UpdateTable",
    ]
    resources = [
      "arn:aws:glue:${local.region}:${local.account_id}:catalog",
      "arn:aws:glue:${local.region}:${local.account_id}:database/${var.catalog_prefix}_*",
      "arn:aws:glue:${local.region}:${local.account_id}:table/${var.catalog_prefix}_*/*",
    ]
  }

  statement {
    sid       = "ListLake"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [local.lake_bucket_arn]
  }

  statement {
    sid       = "ReadBronze"
    actions   = ["s3:GetObject"]
    resources = ["${local.lake_bucket_arn}/raw/*"]
  }

  statement {
    sid     = "WriteBuildsAuditAndResults"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
    resources = [
      "${local.lake_bucket_arn}/builds/*",
      "${local.lake_bucket_arn}/audit/*",
      "${local.lake_bucket_arn}/athena-results/pipeline/*",
    ]
  }

  statement {
    sid       = "ReadUpdateManifest"
    actions   = ["dynamodb:Scan", "dynamodb:UpdateItem"]
    resources = ["arn:aws:dynamodb:${local.region}:${local.account_id}:table/${var.manifest_table_name}"]
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = "pipeline"
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

# ---------- State machine ----------

locals {
  # r20261009_183005, from the execution start time: unique per run and valid in table names.
  run_id_expression = "'r' & $replace($replace($replace($substring($states.context.Execution.StartTime, 0, 19), '-', ''), ':', ''), 'T', '_')"

  athena_retry = [{
    ErrorEquals     = ["Athena.TooManyRequestsException"]
    IntervalSeconds = 5
    MaxAttempts     = 3
    BackoffRate     = 2
  }]

  # One Map iteration per SQL statement, one at a time and in order. Each iteration starts the query,
  # then checks every 3 seconds until it finishes. (The .sync integration only checks about once a
  # minute, which made every statement take a minute.) State names must be unique across the whole
  # state machine, so each Map gets its own copy, named after its step.
  query_processors = {
    for step in ["Build", "Gate", "Publish"] : step => {
      ProcessorConfig = { Mode = "INLINE" }
      StartAt         = "Start${step}Query"
      States = {
        ("Start${step}Query") = {
          Type     = "Task"
          Resource = "arn:aws:states:::athena:startQueryExecution"
          Arguments = {
            QueryString = "{% $replace($states.input, '__RUN_ID__', $run_id) %}"
            WorkGroup   = var.athena_workgroup_name
          }
          Output = { QueryExecutionId = "{% $states.result.QueryExecutionId %}" }
          Retry  = local.athena_retry
          Next   = "Wait${step}Query"
        }
        ("Wait${step}Query") = {
          Type    = "Wait"
          Seconds = 3
          Next    = "Check${step}Query"
        }
        ("Check${step}Query") = {
          Type      = "Task"
          Resource  = "arn:aws:states:::athena:getQueryExecution"
          Arguments = { QueryExecutionId = "{% $states.input.QueryExecutionId %}" }
          Output = {
            QueryExecutionId = "{% $states.result.QueryExecution.QueryExecutionId %}"
            State            = "{% $states.result.QueryExecution.Status.State %}"
            Reason           = "{% $exists($states.result.QueryExecution.Status.StateChangeReason) ? $states.result.QueryExecution.Status.StateChangeReason : '' %}"
          }
          Retry = local.athena_retry
          Next  = "${step}QueryFinished"
        }
        ("${step}QueryFinished") = {
          Type = "Choice"
          Choices = [
            { Condition = "{% $states.input.State = 'SUCCEEDED' %}", Next = "${step}QuerySucceeded" },
            { Condition = "{% $states.input.State in ['FAILED', 'CANCELLED'] %}", Next = "${step}QueryFailed" },
          ]
          Default = "Wait${step}Query"
        }
        ("${step}QuerySucceeded") = { Type = "Succeed" }
        ("${step}QueryFailed") = {
          Type  = "Fail"
          Error = "QueryFailed"
          Cause = "{% $states.input.Reason %}"
        }
      }
    }
  }
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = "${var.name_prefix}-pipeline"
  role_arn = aws_iam_role.pipeline.arn

  definition = jsonencode({
    Comment        = "Copy from Drive, build silver and gold, check, and publish only if the checks pass"
    QueryLanguage  = "JSONata"
    TimeoutSeconds = 7200
    StartAt        = "Start"
    States = {
      Start = {
        Type   = "Pass"
        Assign = { run_id = "{% ${local.run_id_expression} %}" }
        Next   = "CopyFromDrive"
      }

      CopyFromDrive = {
        Type      = "Task"
        Resource  = "arn:aws:states:::glue:startJobRun.sync"
        Arguments = { JobName = var.glue_job_name }
        Next      = "FindLandedFiles"
      }

      FindLandedFiles = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:dynamodb:scan"
        Arguments = {
          TableName                 = var.manifest_table_name
          FilterExpression          = "#status = :landed"
          ExpressionAttributeNames  = { "#status" = "status" }
          ExpressionAttributeValues = { ":landed" = { S = "LANDED" } }
          ProjectionExpression      = "drive_file_id"
        }
        Assign = { landed = "{% $states.result.Items %}" }
        Next   = "AnythingToBuild"
      }

      AnythingToBuild = {
        Type    = "Choice"
        Choices = [{ Condition = "{% $count($landed) > 0 %}", Next = "BuildAndAudit" }]
        Default = "NothingToBuild"
      }

      NothingToBuild = { Type = "Succeed" }

      BuildAndAudit = {
        Type           = "Map"
        Items          = local.build_sql
        MaxConcurrency = 1
        ItemProcessor  = local.query_processors["Build"]
        Next           = "CountFailedChecks"
      }

      CountFailedChecks = {
        Type           = "Map"
        Items          = [local.failed_checks_sql]
        MaxConcurrency = 1
        ItemProcessor  = local.query_processors["Gate"]
        Next           = "ReadFailedChecks"
      }

      ReadFailedChecks = {
        Type      = "Task"
        Resource  = "arn:aws:states:::athena:getQueryResults"
        Arguments = { QueryExecutionId = "{% $states.input[0].QueryExecutionId %}" }
        Assign    = { failed_checks = "{% $number($states.result.ResultSet.Rows[1].Data[0].VarCharValue) %}" }
        Next      = "ChecksPassed"
      }

      ChecksPassed = {
        Type    = "Choice"
        Choices = [{ Condition = "{% $failed_checks = 0 %}", Next = "Publish" }]
        Default = "ChecksFailed"
      }

      ChecksFailed = {
        Type  = "Fail"
        Error = "ChecksFailed"
        Cause = "{% $string($failed_checks) & ' error-level checks failed in run ' & $run_id & '. Nothing was published: see audit.check_results.' %}"
      }

      Publish = {
        Type           = "Map"
        Items          = local.publish_sql
        MaxConcurrency = 1
        ItemProcessor  = local.query_processors["Publish"]
        Next           = "MarkProcessed"
      }

      MarkProcessed = {
        Type           = "Map"
        Items          = "{% $landed %}"
        MaxConcurrency = 10
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }
          StartAt         = "MarkOneProcessed"
          States = {
            MarkOneProcessed = {
              Type     = "Task"
              Resource = "arn:aws:states:::dynamodb:updateItem"
              Arguments = {
                TableName                 = var.manifest_table_name
                Key                       = { drive_file_id = "{% $states.input.drive_file_id %}" }
                UpdateExpression          = "SET #status = :processed"
                ExpressionAttributeNames  = { "#status" = "status" }
                ExpressionAttributeValues = { ":processed" = { S = "PROCESSED" } }
              }
              End = true
            }
          }
        }
        End = true
      }
    }
  })
}
