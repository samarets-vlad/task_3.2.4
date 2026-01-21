#!/bin/bash
set -x
# Логування
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo ">>> STAGE 1: SYSTEM INIT"
# SSH Key
mkdir -p /home/ec2-user/.ssh
echo "${ssh_key}" >> /home/ec2-user/.ssh/authorized_keys
chmod 700 /home/ec2-user/.ssh
chmod 600 /home/ec2-user/.ssh/authorized_keys
chown -R ec2-user:ec2-user /home/ec2-user/.ssh

# Swap
SWAP_FILE="/swapfile"
if [ ! -f "$SWAP_FILE" ]; then
    fallocate -l 4G "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
fi

echo ">>> STAGE 2: INSTALL PACKAGES"
dnf update -y
dnf install -y --allowerasing docker nginx cronie git python3-pip ruby wget bind-utils inotify-tools awscli curl amazon-cloudwatch-agent

systemctl enable --now docker
systemctl enable --now nginx
systemctl enable --now crond
usermod -aG docker ec2-user

# Docker Compose
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.24.1/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

echo ">>> STAGE 3: CLOUDWATCH SETUP"
cat <<CW_CONFIG > /opt/aws/amazon-cloudwatch-agent/bin/config.json
{
  "agent": { "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/nginx/access.log", "log_group_name": "ghostfolio-nginx-access", "log_stream_name": "{instance_id}" },
          { "file_path": "/var/log/nginx/error.log", "log_group_name": "ghostfolio-nginx-error", "log_stream_name": "{instance_id}" },
          { "file_path": "/var/log/user-data.log", "log_group_name": "ghostfolio-user-data", "log_stream_name": "{instance_id}" }
        ]
      }
    }
  }
}
CW_CONFIG
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json -s

echo ">>> STAGE 4: ENV CONFIGURATION"
# ТУТ МИ ВИКОРИСТОВУЄМО ЗМІННІ TERRAFORM, ЩОБ НЕ ХАРДКОДИТИ ПАРОЛІ В ФАЙЛІ
cat <<ENV > /home/ec2-user/.env.infra
# Database
POSTGRES_USER=root
POSTGRES_PASSWORD=${postgres_password}
POSTGRES_DB=ghostfolio

# App Security
ACCESS_TOKEN_SALT=${access_token_salt}
JWT_SECRET_KEY=${jwt_secret_key}
NODE_ENV=production

# Redis
REDIS_URL=rediss://:${redis_password}@${redis_host}:${redis_port}

REDIS_HOST=${redis_host}
REDIS_PORT=${redis_port}
REDIS_PASSWORD=${redis_password}

# AWS Logging
AWS_REGION=us-east-1
AWS_LOG_GROUP_APP=ghostfolio-app-logs
AWS_LOG_GROUP_DB=ghostfolio-db-logs
ENV

chown ec2-user:ec2-user /home/ec2-user/.env.infra
chmod 600 /home/ec2-user/.env.infra

# Логін в ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 170934847890.dkr.ecr.us-east-1.amazonaws.com

echo ">>> STAGE 5: NGINX & SSL"
cat <<NGINX > /etc/nginx/conf.d/ghostfolio.conf
server {
    listen 80;
    server_name ${domain_name};
    location / {
        proxy_pass http://127.0.0.1:3333;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX
systemctl reload nginx

# Certbot
python3 -m venv /opt/certbot
/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install certbot certbot-nginx
ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)
MAX_RETRIES=60
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    CURRENT_DNS=$(dig +short ${domain_name} | tail -n1)
    if [ "$CURRENT_DNS" == "$PUBLIC_IP" ]; then
        certbot --nginx --non-interactive --agree-tos --email "admin@${domain_name}" -d "${domain_name}" --redirect
        break
    fi
    sleep 10
    COUNT=$((COUNT+1))
done

echo ">>> STAGE 6: BACKUP & AUTOMATION"
# Watcher - ВИПРАВЛЕНО
cat <<'WATCHER' > /usr/local/bin/docker-compose-watcher.sh
#!/bin/bash
# Вказуємо папку, де реально лежить docker-compose.yml
# (Якщо в тебе він лежить в папці ghostfolio/docker, то шлях має бути таким)
TARGET_DIR="/home/ec2-user/ghostfolio" 
FILE_NAME="docker/docker-compose.yml"

while true; do
  # Чекаємо змін у файлі
  inotifywait -e close_write "$TARGET_DIR/$FILE_NAME"
  
  cd "$TARGET_DIR"
  
  # Оновлюємо образи
  docker compose -f docker/docker-compose.yml pull

  aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 170934847890.dkr.ecr.us-east-1.amazonaws.com

  # Запускаємо з підстановкою змінних з .env.infra
  docker compose --env-file /home/ec2-user/.env.infra -f /home/ec2-user/ghostfolio/docker-compose.yml up -d
done
WATCHER
chmod +x /usr/local/bin/docker-compose-watcher.sh

cat <<SERVICE > /etc/systemd/system/docker-watcher.service
[Unit]
Description=Docker Watcher
After=docker.service network.target
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/docker-compose-watcher.sh
Restart=always
[Install]
WantedBy=multi-user.target
SERVICE
systemctl enable --now docker-watcher.service

# Backup
cat <<BACKUP > /usr/local/bin/db_backup.sh
#!/bin/bash
TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="ghostfolio_db_\$TIMESTAMP.sql"
BACKUP_PATH="/tmp/\$BACKUP_NAME"
S3_PATH="s3://${s3_bucket_name}/backups/\$BACKUP_NAME"

# Тут теж використовуємо root (вже всередині контейнера, тому ок)
docker exec gf-postgres pg_dump -U root ghostfolio > \$BACKUP_PATH
aws s3 cp \$BACKUP_PATH \$S3_PATH
rm \$BACKUP_PATH
BACKUP
chmod +x /usr/local/bin/db_backup.sh
echo "0 3 * * * /usr/local/bin/db_backup.sh >> /var/log/backup.log 2>&1" | crontab -

echo "Setup Complete!"

# --- STAGE 7: CLEANUP (ДЛЯ БЕЗПЕКИ) ---
# Видаляємо цей скрипт з історії user-data, щоб паролі не висіли в кеші Cloud-Init
rm -f /var/lib/cloud/instance/user-data.txt
rm -f /var/lib/cloud/instance/scripts/part-001