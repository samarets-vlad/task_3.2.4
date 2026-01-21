variable "vpc_id" {}
variable "subnet_ids" { type = list(string) }
variable "allowed_security_group_id" {}
variable "redis_password" { sensitive = true }