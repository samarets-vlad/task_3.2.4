output "server_public_ip" {
  description = "Elastic IP address"
  value       = aws_eip.web.public_ip
}
