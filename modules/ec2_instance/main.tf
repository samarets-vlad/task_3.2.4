terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
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

  # 1. ПОДКЛЮЧАЕМ SSH КЛЮЧ [FIX]
  key_name             = var.key_name
  
  # 2. ПОДКЛЮЧАЕМ IAM РОЛЬ (Task 3.2.6)
  iam_instance_profile = var.iam_instance_profile_name 

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
  }

  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  associate_public_ip_address = true

  tags = {
    Name = "Ghostfolio-App"
  }

  user_data = <<-EOF
#!/bin/bash
set -x

# Логируем вывод
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

DOMAIN="${var.domain_name}"
EMAIL="admin@$DOMAIN"
S3_BUCKET="${var.s3_bucket_name}"

echo "Starting setup for $DOMAIN..."

# --- 1. УСТАНОВКА DOCKER (ИСПРАВЛЕННЫЙ МЕТОД) ---
dnf update -y
# inotify-tools нужен для Watcher
dnf install -y git wget bind-utils inotify-tools

# Устанавливаем Docker Engine из стандартного репозитория
dnf install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user

# Устанавливаем Docker Compose ВРУЧНУЮ (чтобы избежать 404 ошибок)
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.24.1/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Алиас
echo 'alias docker-compose="docker compose"' >> /home/ec2-user/.bashrc

# --- 2. NGINX & SSL ---
systemctl enable --now nginx

cat <<NGINX > /etc/nginx/conf.d/ghostfolio.conf
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:3333;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

nginx -t
systemctl reload nginx

# --- 3. ЗАПУСК ПРИЛОЖЕНИЯ ---
cd /home/ec2-user
if [ ! -d ghostfolio ]; then
    git clone https://github.com/ghostfolio/ghostfolio.git
    chown -R ec2-user:ec2-user ghostfolio
fi
# Копируем конфиг (он создает юзера 'user' и базу 'ghostfolio-db')
cp -n /home/ec2-user/ghostfolio/.env.example /home/ec2-user/ghostfolio/.env || true

# Запуск от имени ec2-user
runuser -l ec2-user -c "cd /home/ec2-user/ghostfolio && docker compose -f docker/docker-compose.yml up -d"

# --- 4. CERTBOT ---
python3 -m venv /opt/certbot
/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install certbot certbot-nginx
ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)
MAX_RETRIES=60 
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    CURRENT_DNS=$(dig +short $DOMAIN | tail -n1)
    if [ "$CURRENT_DNS" == "$PUBLIC_IP" ]; then
        break
    fi
    sleep 10
    COUNT=$((COUNT+1))
done

if [ "$CURRENT_DNS" == "$PUBLIC_IP" ]; then
    certbot --nginx --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN" --redirect
fi

# --- 5. WATCHER SCRIPT ---
cat <<'WATCHER' > /usr/local/bin/docker-compose-watcher.sh
#!/bin/bash
TARGET_DIR="/home/ec2-user/ghostfolio"
FILE_NAME="docker-compose.yml"
while true; do
  inotifywait -e close_write "$TARGET_DIR/$FILE_NAME"
  cd "$TARGET_DIR"
  docker compose pull
  docker compose up -d
done
WATCHER
chmod +x /usr/local/bin/docker-compose-watcher.sh

cat <<SERVICE > /etc/systemd/system/docker-watcher.service
[Unit]
Description=Docker Compose Watcher
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

# --- 6. СКРИПТ БЭКАПА (ФИНАЛЬНЫЙ) ---
# Используем правильные переменные и экранирование
cat <<BACKUP > /usr/local/bin/db_backup.sh
#!/bin/bash
TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="ghostfolio_db_\$TIMESTAMP.sql"
BACKUP_PATH="/tmp/\$BACKUP_NAME"
S3_PATH="s3://${var.s3_bucket_name}/backups/\$BACKUP_NAME"

echo "Starting backup..."

# Используем 'user' и 'ghostfolio-db' (проверено вручную)
docker exec gf-postgres pg_dump -U user ghostfolio-db > \$BACKUP_PATH

aws s3 cp \$BACKUP_PATH \$S3_PATH
rm \$BACKUP_PATH
echo "Done!"
BACKUP

chmod +x /usr/local/bin/db_backup.sh

# --- 7. CRON JOB ---
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/db_backup.sh >> /var/log/backup.log 2>&1") | crontab -

echo "Setup Complete!"
EOF
}