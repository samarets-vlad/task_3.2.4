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
