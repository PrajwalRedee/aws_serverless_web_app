output "api_invoke_url" {
  description = "Full API invoke URL (HTTP API)"
  value       = format("%s/%s", aws_apigatewayv2_api.notes.api_endpoint, aws_apigatewayv2_stage.dev.name)
}

output "s3_website_url" {
  description = "S3 website URL (frontend)"
  value       = aws_s3_bucket_website_configuration.frontend.website_endpoint
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.users.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.client.id
}

output "cognito_domain" {
  value = aws_cognito_user_pool_domain.domain.domain
}
