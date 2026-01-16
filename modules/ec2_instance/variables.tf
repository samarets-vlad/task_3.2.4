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
