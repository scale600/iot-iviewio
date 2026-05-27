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

variable "acm_cert_arn" {
  description = "ARN of the ACM certificate for iot.iviewio.com"
  type        = string
}

resource "aws_iot_domain_configuration" "custom_domain" {
  name                    = "iot-iviewio-custom-domain"
  domain_name             = "iot.iviewio.com"
  server_certificate_arns = [var.acm_cert_arn]
  status                  = "ENABLED"
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
        Action   = ["iot:Subscribe"]
        Resource = [
          "arn:aws:iot:${var.aws_region}:*:topicfilter/device/Trailer_Sim_01/command",
          "arn:aws:iot:${var.aws_region}:*:topicfilter/$aws/things/Trailer_Sim_01/shadow/update/delta",
          "arn:aws:iot:${var.aws_region}:*:topicfilter/$aws/things/Trailer_Sim_01/jobs/notify-next",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["iot:Receive"]
        Resource = [
          "arn:aws:iot:${var.aws_region}:*:topic/device/Trailer_Sim_01/command",
          "arn:aws:iot:${var.aws_region}:*:topic/$aws/things/Trailer_Sim_01/shadow/update/delta",
          "arn:aws:iot:${var.aws_region}:*:topic/$aws/things/Trailer_Sim_01/jobs/notify-next",
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
  rest_api_id      = aws_api_gateway_rest_api.iot_api.id
  resource_id      = aws_api_gateway_resource.command.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
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
# Lambda: Telemetry Query (GET API)
# ──────────────────────────────────────────

data "archive_file" "query_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/telemetry_query.py"
  output_path = "${path.module}/.build/telemetry_query.zip"
}

resource "aws_lambda_function" "telemetry_query" {
  function_name    = "IoTTelemetryQuery"
  filename         = data.archive_file.query_zip.output_path
  source_code_hash = data.archive_file.query_zip.output_base64sha256
  handler          = "telemetry_query.handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_role.arn

  environment {
    variables = {
      TELEMETRY_TABLE      = aws_dynamodb_table.telemetry.name
      TEMP_ALERT_THRESHOLD = "60.0"
    }
  }
}

resource "aws_api_gateway_resource" "telemetry" {
  rest_api_id = aws_api_gateway_rest_api.iot_api.id
  parent_id   = aws_api_gateway_resource.device_id.id
  path_part   = "telemetry"
}

resource "aws_api_gateway_method" "get_telemetry" {
  rest_api_id      = aws_api_gateway_rest_api.iot_api.id
  resource_id      = aws_api_gateway_resource.telemetry.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "telemetry_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.iot_api.id
  resource_id             = aws_api_gateway_resource.telemetry.id
  http_method             = aws_api_gateway_method.get_telemetry.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.telemetry_query.invoke_arn
}

resource "aws_lambda_permission" "apigw_invoke_query" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.telemetry_query.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.iot_api.execution_arn}/*/*"
}

resource "aws_api_gateway_method" "options_telemetry" {
  rest_api_id   = aws_api_gateway_rest_api.iot_api.id
  resource_id   = aws_api_gateway_resource.telemetry.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_telemetry" {
  rest_api_id = aws_api_gateway_rest_api.iot_api.id
  resource_id = aws_api_gateway_resource.telemetry.id
  http_method = aws_api_gateway_method.options_telemetry.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "options_telemetry" {
  rest_api_id = aws_api_gateway_rest_api.iot_api.id
  resource_id = aws_api_gateway_resource.telemetry.id
  http_method = aws_api_gateway_method.options_telemetry.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_telemetry" {
  rest_api_id = aws_api_gateway_rest_api.iot_api.id
  resource_id = aws_api_gateway_resource.telemetry.id
  http_method = aws_api_gateway_method.options_telemetry.http_method
  status_code = aws_api_gateway_method_response.options_telemetry.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Api-Key'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.options_telemetry]
}

resource "aws_api_gateway_method" "options_command" {
  rest_api_id   = aws_api_gateway_rest_api.iot_api.id
  resource_id   = aws_api_gateway_resource.command.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_command" {
  rest_api_id = aws_api_gateway_rest_api.iot_api.id
  resource_id = aws_api_gateway_resource.command.id
  http_method = aws_api_gateway_method.options_command.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "options_command" {
  rest_api_id = aws_api_gateway_rest_api.iot_api.id
  resource_id = aws_api_gateway_resource.command.id
  http_method = aws_api_gateway_method.options_command.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_command" {
  rest_api_id = aws_api_gateway_rest_api.iot_api.id
  resource_id = aws_api_gateway_resource.command.id
  http_method = aws_api_gateway_method.options_command.http_method
  status_code = aws_api_gateway_method_response.options_command.status_code
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Api-Key'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.options_command]
}

resource "aws_api_gateway_deployment" "prod_v2" {
  rest_api_id = aws_api_gateway_rest_api.iot_api.id
  stage_name  = "prod"
  depends_on  = [
    aws_api_gateway_integration.command_lambda,
    aws_api_gateway_integration.telemetry_lambda,
    aws_api_gateway_integration_response.options_telemetry,
    aws_api_gateway_integration_response.options_command,
  ]

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.telemetry.id,
      aws_api_gateway_method.get_telemetry.id,
      aws_api_gateway_integration.telemetry_lambda.id,
      aws_api_gateway_method.options_telemetry.id,
      aws_api_gateway_method.options_command.id,
    ]))
  }
}

resource "aws_api_gateway_api_key" "dashboard" {
  name    = "IoTDashboardKey"
  enabled = true
}

resource "aws_api_gateway_usage_plan" "dashboard" {
  name = "IoTDashboardUsagePlan"
  api_stages {
    api_id = aws_api_gateway_rest_api.iot_api.id
    stage  = "prod"
  }
}

resource "aws_api_gateway_usage_plan_key" "dashboard" {
  key_id        = aws_api_gateway_api_key.dashboard.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.dashboard.id
}

# ──────────────────────────────────────────
# S3: Dashboard Static Website
# ──────────────────────────────────────────

resource "aws_s3_bucket" "dashboard" {
  bucket_prefix = "iot-dashboard-"
}

resource "aws_s3_bucket_website_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  index_document { suffix = "index.html" }
}

resource "aws_s3_bucket_public_access_block" "dashboard" {
  bucket                  = aws_s3_bucket.dashboard.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "dashboard" {
  bucket     = aws_s3_bucket.dashboard.id
  depends_on = [aws_s3_bucket_public_access_block.dashboard]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.dashboard.arn}/*"
    }]
  })
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

output "iot_custom_domain_name" {
  value = aws_iot_domain_configuration.custom_domain.domain_name
}

resource "aws_cloudfront_distribution" "dashboard" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = ["dashboard.iviewio.com"]
  price_class         = "PriceClass_100"

  origin {
    domain_name = aws_s3_bucket_website_configuration.dashboard.website_endpoint
    origin_id   = "s3-dashboard"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-dashboard"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 300
    max_ttl     = 3600
  }

  viewer_certificate {
    acm_certificate_arn      = "arn:aws:acm:us-east-1:753523452116:certificate/05790033-ee85-466e-acb3-fc8d0ade52e0"
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }
}

output "dashboard_url" {
  value = "https://dashboard.iviewio.com"
}

output "dashboard_cloudfront_domain" {
  value = aws_cloudfront_distribution.dashboard.domain_name
}

output "dashboard_api_key" {
  value     = aws_api_gateway_api_key.dashboard.value
  sensitive = true
}

output "telemetry_api_url" {
  value = "https://${aws_api_gateway_rest_api.iot_api.id}.execute-api.${var.aws_region}.amazonaws.com/prod/device/Trailer_Sim_01/telemetry"
}
