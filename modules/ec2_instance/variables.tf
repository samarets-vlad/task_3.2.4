variable "subnet_id" {
  description = "ID of the subnet where the instance will be created"
  type        = string
}

variable "security_group_id" {
  description = "ID of the security group to attach to the instance"
  type        = string
}

variable "domain_name" {
  description = "Domain name for the application"
  type        = string
}

variable "enable_eip" {
  type    = bool
  default = false
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket for database backups"
  type        = string
}

variable "iam_instance_profile_name" {
  description = "The name of the IAM instance profile to attach to the EC2"
  type        = string
}