output "public_ip" {
  description = "Instance public IP (may change)"
  value       = aws_instance.web.public_ip
}

output "instance_id" {
  description = "EC2 instance id"
  value       = aws_instance.web.id
}
