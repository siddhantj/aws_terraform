#
# AWS Data Exchange automated revision export to S3 upon published Cloudwatch event 
#

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.25.0"
    }
  }
}

# Configure AWS Provider account & target region
provider "aws" {
  profile = "default"
  region  = "us-east-1"
}

# Require dataset ID and initial revision ID to be input before the deployment can take place (the dataset must be subscribed to manually in the AWS Console)
variable "datasetID" {
  type        = string
  description = "ADX Heart Beat Test dataset"
}

variable "revisionID" {
  type        = string
  description = "REQUIRED: the ID for an initial Revision to download immediately."
}

# Create S3 bucket to store exported data in
resource "aws_s3_bucket" "DataS3Bucket" {
  bucket_prefix = "datas3bucket"
}

# Apply all Public Access Block controls by default
resource "aws_s3_bucket_public_access_block" "DataS3BucketPublicAccessBlock" {
  bucket                  = aws_s3_bucket.DataS3Bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# resource "aws_s3_bucket_object" "adx_s3_folder" {
#   bucket       = aws_s3_bucket.DataS3Bucket.id
#   key          = "adx_s3_folder/"
#   content_type = "application/x-directory"
# }


# Create new EventBridge rule to trigger on the Revision Published To Data Set event .This is invocation
resource "aws_cloudwatch_event_rule" "NewRevisionEventRule" {
  name        = "NewRevisionEventRule"
  description = "New Revision Event"
  event_pattern = jsonencode({
    source      = ["aws.dataexchange"],
    detail-type = ["Revision Published To Data Set"],
    resources   = [var.datasetID]
  })
}

# Create trigger for EventBRidge rule to Lambda function .This is triggering target
# resource "aws_cloudwatch_event_target" "TargetGetNewRevision" { ## comment this out to see if you see any trigget in cloudwatch. I'm unable to see target_id of this trigger in cloudwatch or lambda
#   rule      = aws_cloudwatch_event_rule.NewRevisionEventRule.name
#   target_id = "TargetGetNewRevision"
#   arn       = aws_lambda_function.FunctionGetNewRevision.arn
# }

# Create Lambda function using Python code included in index.zip
resource "aws_lambda_function" "FunctionGetNewRevision" {
  function_name    = "FunctionGetNewRevision"
  filename         = "index.zip"
  source_code_hash = filebase64sha256("index.zip")
  handler          = "index.handler"
  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.DataS3Bucket.bucket
    }
  }
  role    = aws_iam_role.RoleGetNewRevision.arn
  runtime = "python3.7"
  timeout = 180
}

resource "aws_iam_role_policy_attachment" "RoleGetNewRevisionAttachment" {
  role       = aws_iam_role.RoleGetNewRevision.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Provide permission for EventBridge to invoke Lambda function
resource "aws_lambda_permission" "LambdaInvokePermission" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.FunctionGetNewRevision.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.NewRevisionEventRule.arn
}

# Create Lambda Execution Role
resource "aws_iam_role" "RoleGetNewRevision" {
  name = "RoleGetNewRevision"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Add Required Policies to Lambda Execution Role
resource "aws_iam_role_policy" "RoleGetNewRevisionPolicy" {
  name = "RoleGetNewRevisionPolicy"
  role = aws_iam_role.RoleGetNewRevision.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dataexchange:StartJob",
          "dataexchange:CreateJob",
          "dataexchange:GetJob",
          "dataexchange:ListRevisionAssets",
          "dataexchange:GetAsset"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = "s3:GetObject",
        Resource = "arn:aws:s3:::*aws-data-exchange*"
        Condition = {
          "ForAnyValue:StringEquals" = {
            "aws:CalledVia" = [
              "dataexchange.amazonaws.com"
            ]
          }
        }
      },
      {
        Effect   = "Allow",
        Action   = "sns:*",
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = "sqs:*",
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = "s3:PutObject",
        Resource = [
          aws_s3_bucket.DataS3Bucket.arn,
          join("", [aws_s3_bucket.DataS3Bucket.arn, "/*"])
        ]
      }
    ]
  })
}

# Attach LambdaBasicExecutionRole AWS Managed Policy to Lambda Execution Role(RoleGetNewRevision) ##Test. comment out and see what it does
# resource "aws_iam_role_policy_attachment" "RoleGetNewRevisionAttachment" {
#   role       = aws_iam_role.RoleGetNewRevision.name
#   policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
# }


/*
# Invoke Lambda function for initial data export
data "aws_lambda_invocation" "FistRevision" {
  function_name = aws_lambda_function.FunctionGetNewRevision.function_name
  input = jsonencode(
    {
      InitialInit = {
        data_set_id = var.datasetID,
        RevisionIds = var.revisionID
      }
    }
  )
}
*/
# Create SNS topic resource
resource "aws_sns_topic" "adx_sns_topic" {
  name = "adx_sns_topic"
  # display_name = "adx_sns_topic"
}

# Create policy for SNS topic
resource "aws_sns_topic_policy" "adx_sns_topic_policy" {
  arn    = aws_sns_topic.adx_sns_topic.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json

}

data "aws_iam_policy_document" "sns_topic_policy" {
  policy_id = "__default_policy_ID"
  statement {
    actions = [
      "sns:Publish"
    ]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    effect = "Allow"
    resources = [
      aws_sns_topic.adx_sns_topic.arn,
    ]
    sid = "__default_statement_ID"
  }
}

# Create SQS Queue "adx_sns_topic"
resource "aws_sqs_queue" "adx_sqs_queue" {
  name                        = "adx_sqs_queue"
  fifo_queue                  = false
  content_based_deduplication = false # will be true for FIFO
  max_message_size            = 2048
  visibility_timeout_seconds  = 600
}


# Create policy "adx_sqs_queue_policy" and attach it to "adx_sqs_queue"
resource "aws_sqs_queue_policy" "adx_sqs_queue_policy" {
  queue_url = aws_sqs_queue.adx_sqs_queue.id
  policy    = <<POLICY
{
  "Version": "2012-10-17",
  "Id": "sqspolicy",
  "Statement": [
    {
      "Sid": "First",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "sqs:*",
      "Resource": "${aws_sqs_queue.adx_sqs_queue.arn}"
    }
  ]
}
POLICY
}

# Subscribe "adx_sqs_queue" to topic "adx_sns_topic"
resource "aws_sns_topic_subscription" "adx_sns_topic_subscribed_by_adx_sqs_queue" {
  topic_arn = aws_sns_topic.adx_sns_topic.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.adx_sqs_queue.arn
}

# Create trigger for EventBridge/Cloudwatch rule to SNS topic adx_sns_topic .This is triggering target
resource "aws_cloudwatch_event_target" "TargetGetNewRevision" {
  rule      = aws_cloudwatch_event_rule.NewRevisionEventRule.name
  target_id = "TargetGetNewRevision"
  arn       = aws_sns_topic.adx_sns_topic.arn
}

# Setup SQS Queue Trigger for S3 Export Lambda
resource "aws_lambda_event_source_mapping" "s3ExportLambdaTrigger" {
  event_source_arn = aws_sqs_queue.adx_sqs_queue.arn
  function_name    = aws_lambda_function.FunctionGetNewRevision.function_name
}

data "aws_caller_identity" "current" {

}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "caller_arn" {
  value = data.aws_caller_identity.current.arn
}

output "caller_user" {
  value = data.aws_caller_identity.current.user_id
}


# Create SNS topic for AS consumption
resource "aws_sns_topic" "adx-s3export-new-revision-event-topic" {
  name = "adx-s3export-new-revision-event-topic"

}

# Attach policy 'adx-s3export-new-revision-event-topic-policy' to SNS topic 'adx-s3export-new-revision-event-topic'
resource "aws_sns_topic_policy" "adx-s3export-new-revision-event-topic-policy" {
  arn    = aws_sns_topic.adx-s3export-new-revision-event-topic.arn
  policy = data.aws_iam_policy_document.sns_s3export_topic_policy.json

}

data "aws_iam_policy_document" "sns_s3export_topic_policy" {
  policy_id = "__default_policy_ID"
  statement {
    actions = [
      "sns:Publish"
    ]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    effect = "Allow"
    resources = [
      aws_sns_topic.adx-s3export-new-revision-event-topic.arn,
    ]
    sid = "__default_statement_ID"
  }
}

# Create SQS Queue 'adx-s3export-new-revision-event-queue'
resource "aws_sqs_queue" "adx-s3export-new-revision-event-queue" {
  name                        = "adx-s3export-new-revision-event-queue"
  fifo_queue                  = false
  content_based_deduplication = false # will be true for FIFO
  max_message_size            = 2048
  visibility_timeout_seconds  = 600
}

# Create policy "adx-s3export-new-revision-event-queue-policy" and attach it to "adx-s3export-new-revision-event-queue"
resource "aws_sqs_queue_policy" "adx-s3export-new-revision-event-queue-policy" {
  queue_url = aws_sqs_queue.adx-s3export-new-revision-event-queue.id
  policy    = <<POLICY
{
  "Version": "2012-10-17",
  "Id": "sqspolicy",
  "Statement": [
    {
      "Sid": "First",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "sqs:*",
      "Resource": "${aws_sqs_queue.adx-s3export-new-revision-event-queue.arn}"
    }
  ]
}
POLICY
}

# Subscribe "adx-s3export-new-revision-event-queue" to topic "adx-s3export-new-revision-event-topic"
resource "aws_sns_topic_subscription" "adx-s3export-new-revision-event-queue-subscribed-to-adx-s3export-new-revision-event-topic" {
  topic_arn = aws_sns_topic.adx-s3export-new-revision-event-topic.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.adx-s3export-new-revision-event-queue.arn
}
