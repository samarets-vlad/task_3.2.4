data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "web" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro" 

  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  
  
  associate_public_ip_address = true

  tags = {
    Name = "HelloWorld"
  }

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              amazon-linux-extras install nginx1 -y
              systemctl start nginx
              systemctl enable nginx
              EOF
}

resource "aws_eip" "web_ip" {
  count    = var.enable_eip ? 1 : 0
  instance = aws_instance.web.id
  domain   = "vpc"
}