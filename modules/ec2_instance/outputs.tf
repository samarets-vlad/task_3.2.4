output "public_ip" {
  description = "IP адрес сервера"
  value       = aws_instance.web.public_ip
}