terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = { Project = var.project_name, ManagedBy = "terraform" } }
}

# --- KMS ---
resource "aws_kms_key" "main" {
  description             = "${var.project_name} encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}
resource "aws_kms_alias" "main" {
  name          = "alias/${var.project_name}"
  target_key_id = aws_kms_key.main.key_id
}

# --- DynamoDB ---
resource "aws_dynamodb_table" "main" {
  name         = "${var.project_name}-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute { name = "pk"; type = "S" }
  attribute { name = "sk"; type = "S" }

  point_in_time_recovery { enabled = true }
  server_side_encryption  { enabled = true; kms_key_arn = aws_kms_key.main.arn }

  lifecycle { prevent_destroy = true }
}

# --- CloudWatch Log Groups ---
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}
resource "aws_cloudwatch_log_group" "apigw" {
  name              = "/aws/apigateway/${var.project_name}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}

# --- IAM Role for Lambda ---
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["lambda.amazonaws.com"] }
  }
}
data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid     = "DynamoDB"
    actions = ["dynamodb:GetItem","dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:DeleteItem","dynamodb:Query","dynamodb:Scan"]
    resources = [aws_dynamodb_table.main.arn]
  }
  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogStream","logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
  statement {
    sid     = "XRay"
    actions = ["xray:PutTraceSegments","xray:PutTelemetryRecords"]
    resources = ["*"]
  }
  statement {
    sid     = "KMS"
    actions = ["kms:Decrypt","kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }
}
resource "aws_iam_role" "lambda" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_role_policy" "lambda" {
  name   = "inline"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_policy.json
}

# --- Lambda ---
data "archive_file" "handler" {
  type        = "zip"
  output_path = "${path.module}/.build/handler.zip"
  source {
    content  = <<-EOF
      exports.handler = async (event) => {
        const { DynamoDBClient, PutItemCommand } = require("@aws-sdk/client-dynamodb");
        const client = new DynamoDBClient({});
        console.log(JSON.stringify({ event }));
        return { statusCode: 200, body: JSON.stringify({ message: "ok" }) };
      };
    EOF
    filename = "index.js"
  }
}
resource "aws_lambda_function" "api" {
  function_name    = var.project_name
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
  timeout          = 29
  environment {
    variables = { TABLE_NAME = aws_dynamodb_table.main.name, POWERTOOLS_SERVICE_NAME = var.project_name }
  }
  tracing_config { mode = "Active" }
  depends_on = [aws_cloudwatch_log_group.lambda]
}

# --- API Gateway HTTP API ---
resource "aws_apigatewayv2_api" "main" {
  name          = var.project_name
  protocol_type = "HTTP"
}
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    throttling_burst_limit = 500
    throttling_rate_limit  = 1000
  }
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format = jsonencode({ requestId="$context.requestId", ip="$context.identity.sourceIp", method="$context.httpMethod", path="$context.path", status="$context.status", latency="$context.responseLatency" })
  }
}
resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}
resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*/{proxy+}"
}

# --- CloudWatch Alarms ---
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  treat_missing_data  = "notBreaching"
  metric_query {
    id          = "error_rate"
    expression  = "errors/invocations*100"
    label       = "ErrorRate"
    return_data = true
  }
  metric_query {
    id = "errors"
    metric { namespace="AWS/Lambda"; metric_name="Errors"; dimensions={FunctionName=var.project_name}; period=60; stat="Sum" }
  }
  metric_query {
    id = "invocations"
    metric { namespace="AWS/Lambda"; metric_name="Invocations"; dimensions={FunctionName=var.project_name}; period=60; stat="Sum" }
  }
}
resource "aws_cloudwatch_metric_alarm" "dynamo_throttle" {
  alarm_name          = "${var.project_name}-dynamo-throttle"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ThrottledRequests"
  namespace           = "AWS/DynamoDB"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { TableName = aws_dynamodb_table.main.name }
}