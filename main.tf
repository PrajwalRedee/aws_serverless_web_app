terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.region
}

#####################
# DynamoDB
#####################
resource "aws_dynamodb_table" "notes" {
  name         = "NotesTable"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userId"
  range_key    = "noteId"

  attribute {
    name = "userId"
    type = "S"
  }

  attribute {
    name = "noteId"
    type = "S"
  }

  tags = {
    Name = "NotesTable"
  }
}

#####################
# Lambda Role + Policy
#####################
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "lambda_dynamo_exec_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_dynamo" {
  name = "lambda_dynamo_policy"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Scan"
      ],
      Resource = aws_dynamodb_table.notes.arn
    }]
  })
}

#####################
# Lambda Function
#####################
resource "aws_lambda_function" "notes" {
  function_name    = "notes-service"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.9"
  filename         = "${path.module}/lambda/function.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/function.zip")
  timeout          = 30

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.notes.name
    }
  }
}

#####################
# API Gateway (with CORS)
#####################
resource "aws_apigatewayv2_api" "notes" {
  name          = "notes-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins  = ["*"]
    allow_methods  = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers  = ["Authorization", "Content-Type", "X-Amz-Date", "X-Api-Key", "X-Amz-Security-Token"]
    expose_headers = ["*"]
    max_age        = 300
  }
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.notes.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.notes.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_stage" "dev" {
  api_id      = aws_apigatewayv2_api.notes.id
  name        = "dev"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      errorMessage   = "$context.error.message"
      authorizerError = "$context.authorizer.error"
    })
  }
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/notes-api"
  retention_in_days = 7
}

#####################
# Cognito User Pool
#####################
resource "aws_cognito_user_pool" "users" {
  name                     = "notes-user-pool"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Your verification code"
    email_message        = "Your verification code is {####}"
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  password_policy {
    minimum_length    = 8
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
  }

  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }
}

resource "aws_cognito_user_pool_domain" "domain" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.users.id
}

#####################
# S3 Website + CloudFront
#####################
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.s3_bucket_prefix}-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_public_access_block" "frontend_block" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

resource "aws_s3_bucket_policy" "frontend_policy" {
  bucket     = aws_s3_bucket.frontend.id
  depends_on = [aws_s3_bucket_public_access_block.frontend_block]

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "PublicReadGetObject",
      Effect    = "Allow",
      Principal = "*",
      Action    = ["s3:GetObject"],
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
    }]
  })
}

resource "aws_cloudfront_distribution" "frontend_cdn" {
  origin {
    domain_name = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id   = "s3-origin"
  }

  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

#####################
# Cognito Client (uses CloudFront URL for callbacks)
#####################
resource "aws_cognito_user_pool_client" "client" {
  name         = "notes-client"
  user_pool_id = aws_cognito_user_pool.users.id

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH"
  ]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["implicit", "code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = [
    "https://${aws_cloudfront_distribution.frontend_cdn.domain_name}/",
    "https://${aws_cloudfront_distribution.frontend_cdn.domain_name}"
  ]
  
  logout_urls = [
    "https://${aws_cloudfront_distribution.frontend_cdn.domain_name}/"
  ]

  prevent_user_existence_errors = "ENABLED"
  
  # Token validity
  id_token_validity      = 60
  access_token_validity  = 60
  refresh_token_validity = 30
  
  token_validity_units {
    id_token      = "minutes"
    access_token  = "minutes"
    refresh_token = "days"
  }
}

#####################
# API Authorizer + Routes
#####################
resource "aws_apigatewayv2_authorizer" "cognito_auth" {
  api_id           = aws_apigatewayv2_api.notes.id
  name             = "CognitoAuth"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.client.id]
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.users.id}"
  }
}

resource "aws_apigatewayv2_route" "notes" {
  api_id             = aws_apigatewayv2_api.notes.id
  route_key          = "ANY /notes"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_auth.id
}

resource "aws_apigatewayv2_route" "notes_options" {
  api_id    = aws_apigatewayv2_api.notes.id
  route_key = "OPTIONS /notes"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_route" "notes_item" {
  api_id             = aws_apigatewayv2_api.notes.id
  route_key          = "ANY /notes/{noteId}"
  target             = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_auth.id
}

resource "aws_apigatewayv2_route" "notes_item_options" {
  api_id    = aws_apigatewayv2_api.notes.id
  route_key = "OPTIONS /notes/{noteId}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_lambda_permission" "api_gw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notes.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.notes.execution_arn}/*/*"
}

#####################
# Frontend Upload
#####################
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  content_type = "text/html"
  depends_on   = [aws_s3_bucket_policy.frontend_policy]

  content = templatefile("${path.module}/frontend/index.html.tpl", {
    COGNITO_DOMAIN = "https://${aws_cognito_user_pool_domain.domain.domain}.auth.${var.region}.amazoncognito.com",
    CLIENT_ID      = aws_cognito_user_pool_client.client.id,
    REDIRECT_URI   = "https://${aws_cloudfront_distribution.frontend_cdn.domain_name}/",
    API_BASE       = "${aws_apigatewayv2_api.notes.api_endpoint}/${aws_apigatewayv2_stage.dev.name}"
  })
}

#####################
# Outputs - See outputs.tf
#####################