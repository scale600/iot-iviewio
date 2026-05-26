terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

variable "alert_email" {
  description = "Email address to receive high-temperature alerts"
  type        = string
}

# ──────────────────────────────────────────
# IoT Core: Thing + Certificate + Policy
# ──────────────────────────────────────────

resource "aws_iot_thing" "trailer_sim" {
  name = "Trailer_Sim_01"
}

# Managed certificate is created via AWS CLI/console + downloaded locally.
# Reference existing cert ARN here after provisioning.
variable "device_cert_arn" {
  description = "ARN of the X.509 device certificate (created via aws iot create-keys-and-certificate)"
  type        = string
}

resource "aws_iot_policy" "device_policy" {
  name = "TrailerSim01Policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iot:Connect"]
        Resource = "arn:aws:iot:${var.aws_region}:*:client/Trailer_Sim_01"
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Publish"]
        Resource = [
          "arn:aws:iot:${var.aws_region}:*:topic/device/Trailer_Sim_01/telemetry",
          "arn:aws:iot:${var.aws_region}:*:topic/$aws/things/Trailer_Sim_01/shadow/update",
          "arn:aws:iot:${var.aws_region}:*:topic/$aws/things/Trailer_Sim_01/jobs/*/update",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Subscribe", "iot:Receive"]
        Resource = [
          "arn:aws:iot:${var.aws_region}:*:topicfilter/device/Trailer_Sim_01/command",
          "arn:aws:iot:${var.aws_region}:*:topicfilter/$aws/things/Trailer_Sim_01/shadow/update/delta",
          "arn:aws:iot:${var.aws_region}:*:topicfilter/$aws/things/Trailer_Sim_01/jobs/notify-next",
        ]
      },
    ]
  })
}

resource "aws_iot_thing_principal_attachment" "attach_cert" {
  thing     = aws_iot_thing.trailer_sim.name
  principal = var.device_cert_arn
}

resource "aws_iot_policy_attachment" "attach_policy" {
  policy = aws_iot_policy.device_policy.name
  target = var.device_cert_arn
}

# ──────────────────────────────────────────
# DynamoDB: Telemetry Table
# ──────────────────────────────────────────

resource "aws_dynamodb_table" "telemetry" {
  name         = "IoTTelemetry"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "deviceId"
  range_key    = "timestamp"

  attribute {
    name = "deviceId"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "N"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  server_side_encryption {
    enabled = true  # AES-256 via AWS-managed key (ISO 24241: data at rest encryption)
  }
}

# ──────────────────────────────────────────
# SNS: Alert Topic
# ──────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name              = "IoTDeviceAlerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ──────────────────────────────────────────
# IAM: Lambda Execution Role
# ──────────────────────────────────────────

resource "aws_iam_role" "lambda_role" {
  name = "IoTLambdaRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "IoTLambdaPolicy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query"]
        Resource = aws_dynamodb_table.telemetry.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Publish", "iot:UpdateThingShadow"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
    ]
  })
}

# ──────────────────────────────────────────
# Lambda: Telemetry Handler
# ──────────────────────────────────────────

data "aws_iot_endpoint" "current" {
  endpoint_type = "iot:Data-ATS"
}

data "archive_file" "telemetry_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/telemetry_handler.py"
  output_path = "${path.module}/.build/telemetry_handler.zip"
}

resource "aws_lambda_function" "telemetry" {
  function_name    = "IoTTelemetryHandler"
  filename         = data.archive_file.telemetry_zip.output_path
  source_code_hash = data.archive_file.telemetry_zip.output_base64sha256
  handler          = "telemetry_handler.handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_role.arn

  environment {
    variables = {
      TELEMETRY_TABLE      = aws_dynamodb_table.telemetry.name
      ALERT_SNS_TOPIC_ARN  = aws_sns_topic.alerts.arn
      TEMP_ALERT_THRESHOLD = "60.0"
    }
  }
}

# ──────────────────────────────────────────
# Lambda: Command Relay
# ──────────────────────────────────────────

data "archive_file" "command_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/command_relay.py"
  output_path = "${path.module}/.build/command_relay.zip"
}

resource "aws_lambda_function" "command_relay" {
  function_name    = "IoTCommandRelay"
  filename         = data.archive_file.command_zip.output_path
  source_code_hash = data.archive_file.command_zip.output_base64sha256
  handler          = "command_relay.handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_role.arn

  environment {
    variables = {
      IOT_ENDPOINT = data.aws_iot_endpoint.current.endpoint_address
    }
  }
}

# ──────────────────────────────────────────
# IoT Rule → Lambda (Telemetry)
# ──────────────────────────────────────────

resource "aws_iam_role" "iot_rule_role" {
  name = "IoTRuleRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "iot.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "iot_rule_policy" {
  name = "IoTRuleLambdaInvokePolicy"
  role = aws_iam_role.iot_rule_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.telemetry.arn
    }]
  })
}

resource "aws_iot_topic_rule" "telemetry_rule" {
  name        = "TelemetryToLambda"
  enabled     = true
  sql         = "SELECT * FROM 'device/+/telemetry'"
  sql_version = "2016-03-23"

  lambda {
    function_arn = aws_lambda_function.telemetry.arn
  }
}

resource "aws_lambda_permission" "iot_invoke_telemetry" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.telemetry.function_name
  principal     = "iot.amazonaws.com"
  source_arn    = aws_iot_topic_rule.telemetry_rule.arn
}

# ──────────────────────────────────────────
# API Gateway: POST /device/{deviceId}/command
# ──────────────────────────────────────────

resource "aws_api_gateway_rest_api" "iot_api" {
  name = "IoTCommandAPI"
}

resource "aws_api_gateway_resource" "device" {
  rest_api_id = aws_api_gateway_rest_api.iot_api.id
  parent_id   = aws_api_gateway_rest_api.iot_api.root_resource_id
  path_part   = "device"
}

resource "aws_api_gateway_resource" "device_id" {
  rest_api_id = aws_api_gateway_rest_api.iot_api.id
  parent_id   = aws_api_gateway_resource.device.id
  path_part   = "{deviceId}"
}

resource "aws_api_gateway_resource" "command" {
  rest_api_id = aws_api_gateway_rest_api.iot_api.id
  parent_id   = aws_api_gateway_resource.device_id.id
  path_part   = "command"
}

resource "aws_api_gateway_method" "post_command" {
  rest_api_id   = aws_api_gateway_rest_api.iot_api.id
  resource_id   = aws_api_gateway_resource.command.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "command_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.iot_api.id
  resource_id             = aws_api_gateway_resource.command.id
  http_method             = aws_api_gateway_method.post_command.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.command_relay.invoke_arn
}

resource "aws_lambda_permission" "apigw_invoke_command" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.command_relay.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.iot_api.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "prod" {
  rest_api_id = aws_api_gateway_rest_api.iot_api.id
  stage_name  = "prod"
  depends_on  = [aws_api_gateway_integration.command_lambda]
}

# ──────────────────────────────────────────
# S3: OTA Firmware Bucket
# ──────────────────────────────────────────

resource "aws_s3_bucket" "firmware" {
  bucket_prefix = "iot-firmware-"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "firmware" {
  bucket = aws_s3_bucket.firmware.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "firmware" {
  bucket                  = aws_s3_bucket.firmware.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ──────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────

output "iot_endpoint" {
  value = data.aws_iot_endpoint.current.endpoint_address
}

output "api_gateway_url" {
  value = "${aws_api_gateway_deployment.prod.invoke_url}/device/{deviceId}/command"
}

output "firmware_bucket" {
  value = aws_s3_bucket.firmware.bucket
}
