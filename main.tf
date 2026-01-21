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

# --- 1. VPC ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "main-vpc"
  cidr = "10.0.0.0/16"

  azs            = ["us-east-1a"]
  public_subnets = ["10.0.1.0/24"]

  enable_nat_gateway = false
  enable_vpn_gateway = false
}

# --- 2. S3 BACKUPS ---
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "db_backups" {
  bucket = "ghostfolio-backups-${random_id.bucket_suffix.hex}"
}

resource "aws_s3_bucket_lifecycle_configuration" "backup_lifecycle" {
  bucket = aws_s3_bucket.db_backups.id

  rule {
    id     = "archive_and_delete"
    status = "Enabled"

    filter {}

    transition {
      days          = 7
      storage_class = "GLACIER"
    }
    expiration {
      days = 30
    }
  }
}

# --- 3. IAM & SECURITY ---
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

# Дозвіл на читання ECR (Docker Images)
resource "aws_iam_role_policy_attachment" "ecr_read_access" {
  role       = aws_iam_role.s3_backup_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# [NEW] Дозвіл для CloudWatch Agent (Логи)
resource "aws_iam_role_policy_attachment" "cloudwatch_agent_policy" {
  role       = aws_iam_role.s3_backup_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_security_group" "web_sg" {
  name        = "allow_web_traffic"
  description = "Allow Web and SSH inbound traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH"
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

# --- 4. [NEW] REDIS (ELASTICACHE) ---
# Генеруємо надійний пароль для Redis
resource "random_password" "redis_password" {
  length           = 16
  special          = false
}

resource "random_password" "postgres_password" {
  length           = 16
  special          = false
}

resource "random_password" "access_token_salt" {
  length           = 32
  special          = false
}

resource "random_password" "jwt_secret_key" {
  length           = 32
  special          = false
}

module "elasticache" {
  source = "./modules/elasticache"
  
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets
  allowed_security_group_id = aws_security_group.web_sg.id
  redis_password = random_password.redis_password.result
}

# --- 5. EC2 INSTANCE ---
module "web_server" {
  source = "./modules/ec2_instance"

  subnet_id                 = module.vpc.public_subnets[0]
  security_group_id         = aws_security_group.web_sg.id
  domain_name               = var.domain_name
  s3_bucket_name            = aws_s3_bucket.db_backups.id
  iam_instance_profile_name = aws_iam_instance_profile.ec2_profile.name

  redis_endpoint = module.elasticache.redis_endpoint
  redis_port     = module.elasticache.redis_port
  redis_password = random_password.redis_password.result

  
  postgres_password = random_password.postgres_password.result
  access_token_salt = random_password.access_token_salt.result
  jwt_secret_key    = random_password.jwt_secret_key.result
}

# --- 6. ROUTE 53 ---
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