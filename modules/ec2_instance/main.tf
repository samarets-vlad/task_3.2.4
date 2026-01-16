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

echo "Starting setup for $DOMAIN on Amazon Linux 2023..."

# 1. Обновление и установка пакетов 
dnf update -y
dnf install -y nginx docker git python3-pip ruby wget bind-utils
# bind-utils нужен для команды dig

# 2. Запуск Docker
dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine

dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
usermod -aG docker ec2-user

docker compose version
echo 'alias docker-compose="docker compose"' >> /home/ec2-user/.bashrc

# 3. Запуск Nginx 
systemctl enable --now nginx

# конфиг для HTTP 
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

# Проверка и перезапуск Nginx
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

# Запускаем от имени ec2-user
runuser -l ec2-user -c "cd /home/ec2-user/ghostfolio && docker compose -f docker/docker-compose.yml up -d"


# 5. WATCHER SCRIPT
cat <<'WATCHER' > /usr/local/bin/docker-compose-watcher.sh
#!/bin/bash
TARGET_DIR="/home/ec2-user/ghostfolio"
FILE_NAME="docker-compose.yml"

echo "Starting watcher for $TARGET_DIR/$FILE_NAME..."

while true; do
  inotifywait -e close_write "$TARGET_DIR/$FILE_NAME"
  
  echo "File changed! Redeploying..."
  cd "$TARGET_DIR"
  
  docker compose pull
  docker compose up -d
done
WATCHER

chmod +x /usr/local/bin/docker-compose-watcher.sh

# systemd сервіс для watcher
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

# 6. Установка Certbot 
python3 -m venv /opt/certbot
/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install certbot certbot-nginx
ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

# 7. ОЖИДАНИЕ DNS 
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)

echo "Waiting for DNS propagation..."
echo "My IP: $PUBLIC_IP"

MAX_RETRIES=60 # 60 попыток по 10 сек = 10 минут ожидания
COUNT=0

while [ $COUNT -lt $MAX_RETRIES ]; do
    CURRENT_DNS=$(dig +short $DOMAIN | tail -n1)
    
    echo "Check $COUNT: DNS reports $CURRENT_DNS"
    
    if [ "$CURRENT_DNS" == "$PUBLIC_IP" ]; then
        echo "DNS matches! Starting Certbot..."
        break
    fi
    
    sleep 10
    COUNT=$((COUNT+1))
done

if [ "$CURRENT_DNS" != "$PUBLIC_IP" ]; then
    echo "Error: DNS did not propagate in time. Skipping SSL."
    exit 1
fi

# 8. Запуск Certbot
certbot --nginx --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN" --redirect

echo "Setup Complete!"
EOF
}