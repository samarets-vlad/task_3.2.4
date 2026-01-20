terraform {

  required_version = ">= 1.14.3" 
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" 
    }
  }
  
  backend "s3" {
    bucket = "my-test-bucket-20260109192313009400000001"
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_key_pair" "deployer" {
  key_name   = "ghostfolio-key"
  public_key = var.ssh_public_key # Берем значение из variables.tf
}

# 1. ПЕРЕХОД НА ОФИЦИАЛЬНЫЙ МОДУЛЬ VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "main-vpc"
  cidr = "10.0.0.0/16"

  azs            = ["us-east-1a"]
  public_subnets = ["10.0.1.0/24"]

  enable_nat_gateway = false
  enable_vpn_gateway = false
}

# 2. СОЗДАНИЕ S3 БАКЕТА ДЛЯ БЭКАПОВ
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "db_backups" {
  bucket = "ghostfolio-backups-${random_id.bucket_suffix.hex}"
}

# 3. НАСТРОЙКА LIFECYCLE POLICY (Glacier через 7 дней, удаление через 30)
resource "aws_s3_bucket_lifecycle_configuration" "backup_lifecycle" {
  bucket = aws_s3_bucket.db_backups.id

  rule {
    id     = "archive_and_delete"
    status = "Enabled"

    transition {
      days          = 7
      storage_class = "GLACIER"
    }

    expiration {
      days = 30
    }
  }
}

# 4. НАСТРОЙКА IAM РОЛИ ДЛЯ EC2 (Принцип наименьших привилегий)
resource "aws_iam_role" "s3_backup_role" {
  name = "GhostfolioS3BackupRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Политика разрешает только нужные действия с конкретным бакетом
resource "aws_iam_policy" "s3_access" {
  name = "GhostfolioS3Access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
      Effect   = "Allow"
      Resource = ["${aws_s3_bucket.db_backups.arn}", "${aws_s3_bucket.db_backups.arn}/*"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "s3_attach" {
  role       = aws_iam_role.s3_backup_role.name
  policy_arn = aws_iam_policy.s3_access.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ghostfolio_ec2_profile"
  role = aws_iam_role.s3_backup_role.name
}

# 5. ГРУППА БЕЗОПАСНОСТИ (Привязана к новому VPC)
resource "aws_security_group" "web_sg" {
  name        = "allow_web_traffic"
  description = "Allow Web and SSH inbound traffic"
  vpc_id      = module.vpc.vpc_id # Берем ID из модуля

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
    description = "ssh"
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

# 6. МОДУЛЬ СЕРВЕРА
module "web_server" {
  source = "./modules/ec2_instance"

  subnet_id                 = module.vpc.public_subnets[0] # Берем подсеть из модуля
  security_group_id         = aws_security_group.web_sg.id
  domain_name               = var.domain_name
  
  # Передаем новые данные в модуль для настройки бэкапа
  s3_bucket_name            = aws_s3_bucket.db_backups.id
  iam_instance_profile_name = aws_iam_instance_profile.ec2_profile.name

  key_name                  = aws_key_pair.deployer.key_name
}

# 7. ROUTE 53
data "aws_route53_zone" "main" {
  name = var.domain_name
}

resource "aws_route53_record" "web" {
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = var.domain_name
  type            = "A"
  ttl             = "300"
  records         = [module.web_server.public_ip]
  allow_overwrite = true
}

output "server_public_ip" {
  description = "Public IP address of the web server"
  value       = module.web_server.public_ip
}