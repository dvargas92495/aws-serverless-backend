locals {
  path_parts = {
     for path in var.paths:
     path => split("/", path)
  }

  methods = {
      for path in var.paths:
      path => local.path_parts[path][length(local.path_parts[path]) - 1]
  }

  resources = distinct([
    for path in var.paths: local.path_parts[path][0]
  ])

  function_names = {
    for lambda in var.paths:
    lambda => join("_", local.path_parts[lambda])
  }
}

# lambda resource requires either filename or s3... wow
data "archive_file" "dummy" {
  type        = "zip"
  output_path = "./dummy.zip"

  source {
    content   = "// TODO IMPLEMENT"
    filename  = "dummy.js"
  }
}

data "aws_iam_policy_document" "assume_lambda_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name = "${var.api_name}-lambda-execution"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda_policy.json
  tags = var.tags
}

resource "aws_api_gateway_rest_api" "rest_api" {
  name        = var.api_name
  
  endpoint_configuration {
    types = ["REGIONAL"]
  }

  binary_media_types = [
    "multipart/form-data",
    "application/octet-stream"
  ]

  tags = var.tags
}

resource "aws_api_gateway_resource" "resource" {
  for_each    = toset(local.resources)

  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = each.value
}

resource "aws_lambda_function" "lambda_function" {
  for_each      = toset(var.paths)

  function_name = "${var.api_name}_${local.function_names[each.value]}"
  role          = aws_iam_role.lambda_role.arn
  handler       = "${local.function_names[each.value]}.handler"
  filename      = data.archive_file.dummy.output_path
  runtime       = "nodejs12.x"
  publish       = false

  tags = var.tags
}

resource "aws_api_gateway_method" "method" {
  for_each      = toset(var.paths)

  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_resource.resource[local.path_parts[each.value][0]].id
  http_method   = upper(local.methods[each.value])
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "integration" {
  for_each                = toset(var.paths)

  rest_api_id             = aws_api_gateway_rest_api.rest_api.id
  resource_id             = aws_api_gateway_resource.resource[local.path_parts[each.value][0]].id
  http_method             = upper(local.methods[each.value])
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.lambda_function[each.value].invoke_arn
}

resource "aws_lambda_permission" "apigw_lambda" {
  for_each      = toset(var.paths)

  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function[each.value].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.rest_api.execution_arn}/*/*/*"
}

resource "aws_api_gateway_method" "options" {
  for_each      = toset(local.resources)

  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_resource.resource[each.value].id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "mock" {
  for_each             = toset(local.resources)

  rest_api_id          = aws_api_gateway_rest_api.rest_api.id
  resource_id          = aws_api_gateway_resource.resource[each.value].id
  http_method          = aws_api_gateway_method.options[each.value].http_method
  type                 = "MOCK"
  passthrough_behavior = "WHEN_NO_TEMPLATES"

  request_templates = {
    "application/json" = jsonencode(
        {
            statusCode = 200
        }
    )
  }
}

resource "aws_api_gateway_method_response" "mock" {
  for_each    = toset(local.resources)

  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_resource.resource[each.value].id
  http_method = aws_api_gateway_method.options[each.value].http_method
  status_code = "200"
  
  response_models = {
    "application/json" = "Empty"
  }

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers"     = true,
    "method.response.header.Access-Control-Allow-Methods"     = true,
    "method.response.header.Access-Control-Allow-Origin"      = true
  }
}

resource "aws_api_gateway_integration_response" "mock" {
  for_each    = toset(local.resources)

  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_resource.resource[each.value].id
  http_method = aws_api_gateway_method.options[each.value].http_method
  status_code = aws_api_gateway_method_response.mock[each.value].status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers"     = "'Authorization, Content-Type'",
    "method.response.header.Access-Control-Allow-Methods"     = "'GET,DELETE,OPTIONS,POST,PUT'",
    "method.response.header.Access-Control-Allow-Origin"      = "'*'"
  }
}

resource "aws_api_gateway_deployment" "production" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  stage_name  = "production"

  depends_on  = [
    aws_api_gateway_integration.integration, 
    aws_api_gateway_integration.mock, 
    aws_api_gateway_integration_response.mock,
    aws_api_gateway_method.method,
    aws_api_gateway_method.options,
    aws_api_gateway_method_response.mock,
    aws_lambda_permission.apigw_lambda
  ]
}

data "aws_iam_policy_document" "deploy_policy" {
    statement {
      actions = [
        "lambda:UpdateFunctionCode"
      ]

      resources = values(aws_lambda_function.lambda_function)[*].arn
    }
}

resource "aws_iam_user" "update_lambda" {
  name  = "${var.api_name}-lambda"
  path  = "/"
}

resource "aws_iam_access_key" "update_lambda" {
  user  = aws_iam_user.update_lambda.name
}

resource "aws_iam_user_policy" "update_lambda" {
  user   = aws_iam_user.update_lambda.name
  policy = data.aws_iam_policy_document.deploy_policy.json
}