resource "aws_vpc" "main" {

 cidr_block = "10.0.0.0/16"

}

resource "aws_subnet" "main" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "route" {
    vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "together" {
    subnet_id = aws_subnet.main.id
    route_table_id = aws_route_table.route.id
}


resource "aws_security_group" "web_sg" {
  name        = "allow_web_traffic"
  description = "Allow Web and SSH inbound traffic"
  vpc_id      = aws_vpc.main.id  

  ingress {
    description = "HTTP from Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from Internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from Internet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

module "web_server" {
  source = "./modules/ec2_instance"

  subnet_id         = aws_subnet.main.id
  security_group_id = aws_security_group.web_sg.id
  enable_eip        = true
}

output "server_public_ip" {
  description = "Public IP address of the web server"
  value       = module.web_server.public_ip
}