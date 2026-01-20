variable "enable_eip" {
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "The domain name for the application"
  type        = string
  default     = "mydevtasktrain.pp.ua" 
}

variable "enable_eip" {
  type    = bool
  default = false
}

variable "domain_name" {
  description = "The domain name for the application"
  type        = string
  default     = "mydevtasktrain.pp.ua" 
}

variable "ssh_public_key" {
  description = "Public SSH key for EC2 instance"
  type        = string

}