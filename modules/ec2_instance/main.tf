terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "web" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"
  
  iam_instance_profile = var.iam_instance_profile_name 

  # Збільшив до 20, бо логи та образи займають місце
  root_block_device {
    volume_type = "gp3"
    volume_size = 20 
  }

  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  associate_public_ip_address = true

  tags = {
    Name = "Ghostfolio-App"
  }

 
  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    domain_name     = var.domain_name
    s3_bucket_name  = var.s3_bucket_name
    redis_host      = var.redis_endpoint
    redis_port      = var.redis_port
    redis_password  = var.redis_password

    postgres_password = var.postgres_password
    access_token_salt = var.access_token_salt
    jwt_secret_key    = var.jwt_secret_key
    
    ssh_key         = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDx1+MBA4+PxqZh5oaMX52YwC3+t2gQ0QFOhXzhhXQeWAuqNmumLGk3YFQTTQPPUsAa1+nZYjoP+slD4unB78oduXmTzLKZpRNmuTYBTmgSDgcM/XW8Z/egbZuirWxSZJeamI4QvvC6rZszEMrOfyeGKw+wcaZPDkJjQu6zyn5Uyqkhh/lPY0J2mIXLoVgaDW/WWptC8QrorfvMbCUlbHJY8iYVp2wRix0WR0EC2yRXaSH0NWNcYdUatFLUPAZcMKgiV4dwNf4GftfGRWZSWTbiAblMCYg51KvnpB5TyqakUVuFI5BBrry8yXlUBr9LYqTt5I3o4LM6KPQYEW5hwU7Y0YfreHZwvuCwptlGDaO1xfLisgX82838Sfvje4oEg+DJdvEiUHUqMEHm5OMPxpwWeAkHvrDXQQPLm5wGvZwTGfx7egukZQ3qxWB0gJJPPvS5jzdbKOKmXfS4LIvc7x49f5WdIpPr+nS52N+VHI0vG/RTJGYfMxM0bJLxJAcbzsk33vpbo2R+GkPXL6SVAhCGlWw4qOqq+uM/0Ela3DsrGS7NO1mSB1HaUAIps8+Q397Hvsrak2GkQ98v2QlRsIc8D++FnHdFInXSZ4Cq7onuJSQb/FdIRV9st2e+wDQhVcFIoFPpyTuNsUGGLw/zQJL+cRRQ27ujm2HVzjakjSh0EQ== vlad@UbuntuServer"
  })

  user_data_replace_on_change = true
}