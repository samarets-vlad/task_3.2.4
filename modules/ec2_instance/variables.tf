variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

variable "enable_eip" {
  type        = bool
  default     = false
}