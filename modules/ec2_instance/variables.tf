variable "subnet_id" {
  description = "Subnet ID where the instance will be created"
  type        = string
}

variable "security_group_id" {
  description = "Security Group ID to attach to the instance"
  type        = string
}

variable "domain_name" {
  description = "The domain name for the application"
  type        = string
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket for backups"
  type        = string
}

variable "iam_instance_profile_name" {
  description = "IAM Instance Profile name for S3 access"
  type        = string
}

variable "redis_endpoint" {
  description = "Address of ElastiCache Redis"
  type        = string
}

variable "redis_password" {
  description = "Password for Redis"
  type        = string
  sensitive   = true
}

variable "redis_endpoint" {
  description = "Redis endpoint address"
  type        = string
}

variable "redis_port" {
  description = "Redis port"
  type        = number
  default     = 6379
}

variable "redis_password" {
  description = "Redis AUTH token"
  type        = string
  sensitive   = true
}

variable "postgres_password" {
  description = "Password for Postgres DB"
  type        = string
  sensitive   = true
}

variable "access_token_salt" {
  type        = string
  sensitive   = true
}

variable "jwt_secret_key" {
  type        = string
  sensitive   = true
}