output "server_public_ip2" {
  description = "Elastic IP address"
  value       = aws_eip.web.public_ip
}
