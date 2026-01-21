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

  # ПОДКЛЮЧАЕМ IAM РОЛЬ
  iam_instance_profile = var.iam_instance_profile_name 

  root_block_device {
    volume_type = "gp3"
    volume_size = 15
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

# Лог в файл
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo ">>> STAGE 1: SYSTEM INIT"

# 1. SSH ACCESS
mkdir -p /home/ec2-user/.ssh
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDx1+MBA4+PxqZh5oaMX52YwC3+t2gQ0QFOhXzhhXQeWAuqNmumLGk3YFQTTQPPUsAa1+nZYjoP+slD4unB78oduXmTzLKZpRNmuTYBTmgSDgcM/XW8Z/egbZuirWxSZJeamI4QvvC6rZszEMrOfyeGKw+wcaZPDkJjQu6zyn5Uyqkhh/lPY0J2mIXLoVgaDW/WWptC8QrorfvMbCUlbHJY8iYVp2wRix0WR0EC2yRXaSH0NWNcYdUatFLUPAZcMKgiV4dwNf4GftfGRWZSWTbiAblMCYg51KvnpB5TyqakUVuFI5BBrry8yXlUBr9LYqTt5I3o4LM6KPQYEW5hwU7Y0YfreHZwvuCwptlGDaO1xfLisgX82838Sfvje4oEg+DJdvEiUHUqMEHm5OMPxpwWeAkHvrDXQQPLm5wGvZwTGfx7egukZQ3qxWB0gJJPPvS5jzdbKOKmXfS4LIvc7x49f5WdIpPr+nS52N+VHI0vG/RTJGYfMxM0bJLxJAcbzsk33vpbo2R+GkPXL6SVAhCGlWw4qOqq+uM/0Ela3DsrGS7NO1mSB1HaUAIps8+Q397Hvsrak2GkQ98v2QlRsIc8D++FnHdFInXSZ4Cq7onuJSQb/FdIRV9st2e+wDQhVcFIoFPpyTuNsUGGLw/zQJL+cRRQ27ujm2HVzjakjSh0EQ== vlad@UbuntuServer" >> /home/ec2-user/.ssh/authorized_keys
chmod 700 /home/ec2-user/.ssh
chmod 600 /home/ec2-user/.ssh/authorized_keys
chown -R ec2-user:ec2-user /home/ec2-user/.ssh

# 2. SWAP
SWAP_FILE="/swapfile"
if [ ! -f "$SWAP_FILE" ]; then
    fallocate -l 4G "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
fi

echo ">>> STAGE 2: PACKAGE INSTALLATION"

dnf update -y

# 3. BASE TOOLS + CRON (ОКРЕМО)
dnf install -y git wget bind-utils inotify-tools awscli curl cronie python3-pip ruby
systemctl enable --now crond

# 4. NGINX (ОКРЕМО)
dnf install -y nginx
systemctl enable --now nginx

# 5. DOCKER (ОКРЕМО)
dnf install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user

# 6. DOCKER COMPOSE (MANUAL)
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.24.1/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
echo 'alias docker-compose="docker compose"' >> /home/ec2-user/.bashrc

echo ">>> STAGE 3: APP DEPLOYMENT"

DOMAIN="${var.domain_name}"
EMAIL="admin@$DOMAIN"
S3_BUCKET="${var.s3_bucket_name}"

cd /home/ec2-user
if [ ! -d ghostfolio ]; then
    git clone https://github.com/ghostfolio/ghostfolio.git
    chown -R ec2-user:ec2-user ghostfolio
fi

# Створюємо .env і запускаємо
runuser -l ec2-user -c "cd /home/ec2-user/ghostfolio && cp -n .env.example .env"
runuser -l ec2-user -c "cd /home/ec2-user/ghostfolio && docker compose -f docker/docker-compose.yml up -d"

echo ">>> STAGE 4: CONFIGURATION"

# 7. NGINX CONFIG
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
systemctl reload nginx

# 8. SSL (CERTBOT)
python3 -m venv /opt/certbot
/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install certbot certbot-nginx
ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

# Чекаємо DNS
PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)
MAX_RETRIES=60
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    CURRENT_DNS=$(dig +short $DOMAIN | tail -n1)
    if [ "$CURRENT_DNS" == "$PUBLIC_IP" ]; then
        # Запускаємо Certbot
        certbot --nginx --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN" --redirect
        break
    fi
    sleep 10
    COUNT=$((COUNT+1))
done

echo ">>> STAGE 5: AUTOMATION"

# 9. WATCHER SCRIPT
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

# 10. BACKUP SCRIPT
cat <<BACKUP > /usr/local/bin/db_backup.sh
#!/bin/bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="ghostfolio_db_$TIMESTAMP.sql"
BACKUP_PATH="/tmp/$BACKUP_NAME"
S3_PATH="s3://ghostfolio-backups-d8774eea/backups/$BACKUP_NAME"

echo "Starting backup..."
# Перевірено: user / ghostfolio
docker exec gf-postgres pg_dump -U root ghostfolio > $BACKUP_PATH
aws s3 cp $BACKUP_PATH $S3_PATH
rm $BACKUP_PATH
echo "Done!"
BACKUP
chmod +x /usr/local/bin/db_backup.sh

# 11. CRON (Запис в crontab)
echo "0 3 * * * /usr/local/bin/db_backup.sh >> /var/log/backup.log 2>&1" | crontab -

echo "Setup Complete!"
EOF
}