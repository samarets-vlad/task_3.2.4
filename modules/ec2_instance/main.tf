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

# Логируем вывод в файл для отладки
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

DOMAIN="${var.domain_name}"
EMAIL="admin@$DOMAIN"
S3_BUCKET="${var.s3_bucket_name}"

echo "Starting setup for $DOMAIN on Amazon Linux 2023..."

mkdir -p /home/ec2-user/.ssh
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDx1+MBA4+PxqZh5oaMX52YwC3+t2gQ0QFOhXzhhXQeWAuqNmumLGk3YFQTTQPPUsAa1+nZYjoP+slD4unB78oduXmTzLKZpRNmuTYBTmgSDgcM/XW8Z/egbZuirWxSZJeamI4QvvC6rZszEMrOfyeGKw+wcaZPDkJjQu6zyn5Uyqkhh/lPY0J2mIXLoVgaDW/WWptC8QrorfvMbCUlbHJY8iYVp2wRix0WR0EC2yRXaSH0NWNcYdUatFLUPAZcMKgiV4dwNf4GftfGRWZSWTbiAblMCYg51KvnpB5TyqakUVuFI5BBrry8yXlUBr9LYqTt5I3o4LM6KPQYEW5hwU7Y0YfreHZwvuCwptlGDaO1xfLisgX82838Sfvje4oEg+DJdvEiUHUqMEHm5OMPxpwWeAkHvrDXQQPLm5wGvZwTGfx7egukZQ3qxWB0gJJPPvS5jzdbKOKmXfS4LIvc7x49f5WdIpPr+nS52N+VHI0vG/RTJGYfMxM0bJLxJAcbzsk33vpbo2R+GkPXL6SVAhCGlWw4qOqq+uM/0Ela3DsrGS7NO1mSB1HaUAIps8+Q397Hvsrak2GkQ98v2QlRsIc8D++FnHdFInXSZ4Cq7onuJSQb/FdIRV9st2e+wDQhVcFIoFPpyTuNsUGGLw/zQJL+cRRQ27ujm2HVzjakjSh0EQ== vlad@UbuntuServer" >> /home/ec2-user/.ssh/authorized_keys

chmod 700 /home/ec2-user/.ssh
chmod 600 /home/ec2-user/.ssh/authorized_keys
chown -R ec2-user:ec2-user /home/ec2-user/.ssh

# 1. Обновление и установка пакетов 
dnf update -y
# Добавил inotify-tools для работы Watcher Script
dnf install -y nginx docker git python3-pip ruby wget bind-utils inotify-tools

# 2. Установка Docker (официальный репозиторий)
dnf update -y
dnf install -y nginx git python3-pip ruby wget bind-utils inotify-tools awscli curl

dnf remove -y docker docker-client docker-client-latest docker-common docker-latest \
  docker-latest-logrotate docker-logrotate docker-engine || true

dnf -y install dnf-plugins-core

# Docker официально предлагает ставить через их репозиторий (пример для rpm-based) [web:21]
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# Amazon Linux 2023: фикс $releasever, чтобы repo начал отдавать пакеты (частый workaround) [web:22]
sed -i 's/\$releasever/9/g' /etc/yum.repos.d/docker-ce.repo

dnf makecache -y
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

groupadd -f docker
usermod -aG docker ec2-user

echo 'alias docker-compose="docker compose"' >> /home/ec2-user/.bashrc

# быстрая проверка (в лог user-data)
docker --version
docker compose version
# 3. Запуск Nginx (Reverse Proxy)
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

# 4. Запуск приложения Ghostfolio
cd /home/ec2-user
if [ ! -d ghostfolio ]; then
    git clone https://github.com/ghostfolio/ghostfolio.git
    chown -R ec2-user:ec2-user ghostfolio
fi
cd ghostfolio
cp -n .env.example .env || true

# Запускаем Ghostfolio через Docker Compose
runuser -l ec2-user -c "cd /home/ec2-user/ghostfolio && docker compose -f docker/docker-compose.yml up -d"

# 5. Установка Certbot (SSL)
python3 -m venv /opt/certbot
/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install certbot certbot-nginx
ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

# 6. Ожидание DNS для SSL
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

# 7. WATCHER SCRIPT (Авто-перезапуск контейнеров при изменении конфига)
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

# Создание сервиса для Watcher
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

# --- 6. СКРИПТ БЭКАПА  
cat <<BACKUP > /usr/local/bin/db_backup.sh
#!/bin/bash
TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="ghostfolio_db_\$TIMESTAMP.sql"
BACKUP_PATH="/tmp/\$BACKUP_NAME"
S3_PATH="s3://${var.s3_bucket_name}/backups/\$BACKUP_NAME"

echo "Starting backup..."

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