resource "aws_elasticache_subnet_group" "redis_subnet_group" {
  name       = "ghostfolio-redis-subnet-group"
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "redis_sg" {
  name        = "ghostfolio-redis-sg"
  description = "Allow Redis traffic from Web Server"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.allowed_security_group_id] # Дозволяємо тільки від нашого EC2
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_elasticache_replication_group" "ghostfolio_redis" {
  replication_group_id       = "ghostfolio-redis"
  description                = "Ghostfolio Redis Cluster"
  node_type                  = "cache.t3.micro" # Free Tier eligible
  num_cache_clusters         = 1
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.redis_subnet_group.name
  security_group_ids         = [aws_security_group.redis_sg.id]
  
  # Шифрування (потрібне для Auth Token / Пароля)
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = var.redis_password
}