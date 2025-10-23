variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "cognito_domain_prefix" {
  description = "Unique prefix for the Cognito hosted UI domain (must be globally unique per region)"
  type        = string
}

variable "s3_bucket_prefix" {
  description = "Prefix for S3 bucket name"
  type        = string
  default     = "notes-frontend"
}
