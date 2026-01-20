variable "enable_eip" {
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "The domain name for the application"
  type        = string
  default     = "mydevtasktrain.pp.ua" 
}

variable "ssh_public_key" {
  description = "Public SSH key for EC2 instance"
  type        = string
  default     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDx1+MBA4+PxqZh5oaMX52YwC3+t2gQ0QFOhXzhhXQeWAuqNmumLGk3YFQTTQPPUsAa1+nZYjoP+slD4unB78oduXmTzLKZpRNmuTYBTmgSDgcM/XW8Z/egbZuirWxSZJeamI4QvvC6rZszEMrOfyeGKw+wcaZPDkJjQu6zyn5Uyqkhh/lPY0J2mIXLoVgaDW/WWptC8QrorfvMbCUlbHJY8iYVp2wRix0WR0EC2yRXaSH0NWNcYdUatFLUPAZcMKgiV4dwNf4GftfGRWZSWTbiAblMCYg51KvnpB5TyqakUVuFI5BBrry8yXlUBr9LYqTt5I3o4LM6KPQYEW5hwU7Y0YfreHZwvuCwptlGDaO1xfLisgX82838Sfvje4oEg+DJdvEiUHUqMEHm5OMPxpwWeAkHvrDXQQPLm5wGvZwTGfx7egukZQ3qxWB0gJJPPvS5jzdbKOKmXfS4LIvc7x49f5WdIpPr+nS52N+VHI0vG/RTJGYfMxM0bJLxJAcbzsk33vpbo2R+GkPXL6SVAhCGlWw4qOqq+uM/0Ela3DsrGS7NO1mSB1HaUAIps8+Q397Hvsrak2GkQ98v2QlRsIc8D++FnHdFInXSZ4Cq7onuJSQb/FdIRV9st2e+wDQhVcFIoFPpyTuNsUGGLw/zQJL+cRRQ27ujm2HVzjakjSh0EQ== vlad@UbuntuServer"
}