variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Project name used as resource name prefix"
  type        = string
  default     = "serverless-api"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric and hyphens, 3-32 chars."
  }
}