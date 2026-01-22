output "redis_endpoint" {
  value = aws_elasticache_replication_group.ghostfolio_redis.primary_endpoint_address
}

output "redis_port" {
  value = aws_elasticache_replication_group.ghostfolio_redis.port
}
