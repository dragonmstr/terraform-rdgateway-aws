provider "aws" {
  region = var.region
}

locals {
  s3_name        = "${var.s3_prefix}-${var.environment}-${lower(random_string.random.result)}"
  s3_bucket_name = split(".", aws_s3_bucket.certbot.bucket_domain_name)[0]

  route53_zone_id = data.aws_route53_zone.selected.zone_id

  # Wildcard certificate is issued for either *.example.com or *.<var.subdomain_name>.example.com if var.subdomain_name is not null.
  domains = var.subdomain_name == null ? "*.${var.route53_public_zone}" : "*.${var.subdomain_name}${var.route53_public_zone}"

  common_tags = {
    terraform   = "true"
    environment = var.environment
    role        = "letsencrypt-tls"
  }
}

# Use this data source to get the Route 53 zone ID.
data "aws_route53_zone" "selected" {
  name         = var.route53_public_zone
  private_zone = false
}


# The random string needed for injecting randomness in the name of the S3 bucket.
resource "random_string" "random" {
  length  = 12
  special = false
}

# S3 bucket that holds the certbot code.
resource "aws_s3_bucket" "certbot" {
  bucket = local.s3_name
  acl    = "private"

  force_destroy = "true"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "ExpireOldVersionsAfter30Days"
    enabled = true

    noncurrent_version_expiration {
      days = 30
    }
  }

  tags = local.common_tags
}

# Upload the certbot code to S3 bucket.
resource "aws_s3_bucket_object" "certbot_upload" {
  bucket = local.s3_bucket_name
  key    = "certbot-0.27.1.zip"
  source = "./certbot-0.27.1.zip"
  etag   = filemd5("./certbot-0.27.1.zip")
}

# Lambda execution role
resource "aws_iam_role" "execution" {
  name               = "letsencrypt-certbot-lambda-execution"
  assume_role_policy = data.aws_iam_policy_document.assume_execution.json

  tags = local.common_tags
}

# Trust policy for the IAM role
data "aws_iam_policy_document" "assume_execution" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# Template for lambda certbot IAM policy.
data "template_file" "le-certbot-lambda-policy" {
  template = file("${path.module}/le-certbot-lambda-policy.json.tpl")

  vars = {
    s3_bucket_arn    = aws_s3_bucket.certbot.arn
    route53_zone_arn = "arn:aws:route53:::hostedzone/${local.route53_zone_id}"
  }
}

# Lambda certbot IAM policy based on template.
resource "aws_iam_policy" "le-certbot-lambda-policy" {
  name   = "le-certbot-lambda-policy"
  policy = data.template_file.le-certbot-lambda-policy.rendered
}

# Lambda policy attachment to Lambda execution role.
resource "aws_iam_role_policy_attachment" "le-certbot-lambda-policy-attach" {
  role       = aws_iam_role.execution.name
  policy_arn = aws_iam_policy.le-certbot-lambda-policy.arn
}

# Letsencrypt certbot Lambda function.
resource "aws_lambda_function" "le_certbot_lambda" {
  s3_bucket = local.s3_bucket_name
  s3_key    = "certbot-0.27.1.zip"

  # For simplicity, the Lambda function and the S3 bucket that holds its code have the same name.
  function_name = local.s3_name
  role          = aws_iam_role.execution.arn
  handler       = "main.lambda_handler"

  runtime = "python3.6"

  environment {
    variables = {
      domains   = local.domains
      email     = var.email
      s3_bucket = "cert_bucket"
      s3_prefix = "letsencrypt-tls"
    }
  }

  tags = local.common_tags
}

# S3 bucket that holds the Letsencrypt TLS certificates.
resource "aws_s3_bucket" "letsencrypt_tls" {
  bucket = "${var.route53_public_zone}-letsencrypt-tls-${var.region}"
  acl    = "private"

  force_destroy = "true"

  versioning {
    enabled = true
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "aws:kms"
      }
    }
  }

  lifecycle_rule {
    id      = "ExpireOldVersionsAfter30Days"
    enabled = true

    noncurrent_version_expiration {
      days = 30
    }
  }

  tags = local.common_tags
}

# SQS queue that gets notified when new certificate is deposited by certbot Lambda in the S3 bucket. 
resource "aws_sqs_queue" "letsencrypt_tls" {
  name                      = "${local.s3_name}-${var.region}"
 
  tags = local.common_tags
}

# SQS policy.
resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.letsencrypt_tls.id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Id": "SQSQueuePolicy",
  "Statement": [
    {
      "Sid": "Allow-SQS-SendMessage-from-LetsencryptTLSBucket",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "sqs:SendMessage",
      "Resource": "${aws_sqs_queue.letsencrypt_tls.arn}",
      "Condition": {
        "ArnEquals": {
          "aws:SourceArn": "${aws_s3_bucket.letsencrypt_tls.arn}"
        }
      }
    }
  ]
}
POLICY
}