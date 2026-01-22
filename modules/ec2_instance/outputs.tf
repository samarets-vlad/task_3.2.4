output "public_ip" {
  value = aws_instance.web.public_ip
}

output "instance_id" {
  value = aws_instance.web.id
}


output "server_public_ip" {
  value = aws_eip.web.public_ip
}
