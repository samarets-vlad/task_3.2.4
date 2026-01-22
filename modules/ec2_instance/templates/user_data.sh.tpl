#!/bin/bash
set -euxo pipefail

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo ">>> STAGE 1: SYSTEM INIT"

mkdir -p /home/ec2-user/.ssh
echo "${ssh_key}" >> /home/ec2-user/.ssh/authorized_keys
chmod 700 /home/ec2-user/.ssh
chmod 600 /home/ec2-user/.ssh/authorized_keys
chown -R ec2-user:ec2-user /home/ec2-user/.ssh

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
dnf install -y --allowerasing \
  docker nginx cronie git python3-pip ruby wget bind-utils inotify-tools awscli curl \
  amazon-cloudwatch-agent stunnel

systemctl enable --now docker
systemctl enable --now nginx
systemctl enable --now crond
usermod -aG docker ec2-user

# Docker Compose plugin
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fSL "https://github.com/docker/compose/releases/download/v2.24.1/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

echo ">>> STAGE 3: CLOUDWATCH SETUP"
cat > /opt/aws/amazon-cloudwatch-agent/bin/config.json <<'CW_CONFIG'
{
  "agent": { "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "/var/log/nginx/access.log", "log_group_name": "ghostfolio-nginx-access", "log_stream_name": "{instance_id}" },
          { "file_path": "/var/log/nginx/error.log",  "log_group_name": "ghostfolio-nginx-error",  "log_stream_name": "{instance_id}" },
          { "file_path": "/var/log/user-data.log",    "log_group_name": "ghostfolio-user-data",    "log_stream_name": "{instance_id}" }
        ]
      }
    }
  }
}
CW_CONFIG
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json -s

echo ">>> STAGE 4: STUNNEL (REDIS TLS PROXY)"
LOCAL_IP="$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4 || true)"
if [ -z "$LOCAL_IP" ]; then
  LOCAL_IP="$(hostname -I | awk '{print $1}')"
fi

cat > /etc/stunnel/redis-tunnel.conf <<EOF
fips = no
pid = /var/run/stunnel.pid
debug = 4
delay = yes
options = NO_SSLv2
options = NO_SSLv3

[redis]
client = yes
accept = 0.0.0.0:6380
connect = ${redis_host}:${redis_port}
EOF

cat > /etc/systemd/system/stunnel-redis.service <<'EOF'
[Unit]
Description=stunnel TLS tunnel for ElastiCache Redis
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/stunnel /etc/stunnel/redis-tunnel.conf
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now stunnel-redis.service

echo ">>> STAGE 5: ENV CONFIGURATION"
cat > /home/ec2-user/.env.infra <<ENV
POSTGRES_USER=root
POSTGRES_PASSWORD=${postgres_password}
POSTGRES_DB=ghostfolio

ACCESS_TOKEN_SALT=${access_token_salt}
JWT_SECRET_KEY=${jwt_secret_key}
NODE_ENV=production

# Redis через stunnel (TLS снаружи, внутри redis://)
REDIS_PASSWORD=${redis_password}
REDIS_HOST=$LOCAL_IP
REDIS_PORT=6380
REDIS_URL=redis://:${redis_password}@$LOCAL_IP:6380

AWS_REGION=us-east-1
AWS_LOG_GROUP_APP=ghostfolio-app-logs
AWS_LOG_GROUP_DB=ghostfolio-db-logs
ENV

chown ec2-user:ec2-user /home/ec2-user/.env.infra
chmod 600 /home/ec2-user/.env.infra

aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 170934847890.dkr.ecr.us-east-1.amazonaws.com

echo ">>> STAGE 6: NGINX & SSL"
cat > /etc/nginx/conf.d/ghostfolio.conf <<NGINX
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

python3 -m venv /opt/certbot
/opt/certbot/bin/pip install --upgrade pip
/opt/certbot/bin/pip install certbot certbot-nginx
ln -sf /opt/certbot/bin/certbot /usr/bin/certbot

PUBLIC_IP="$(curl -s http://checkip.amazonaws.com || true)"
MAX_RETRIES=60
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
  CURRENT_DNS="$(dig +short ${domain_name} | tail -n1 || true)"
  if [ -n "$PUBLIC_IP" ] && [ "$CURRENT_DNS" = "$PUBLIC_IP" ]; then
    certbot --nginx --non-interactive --agree-tos --email "admin@${domain_name}" -d "${domain_name}" --redirect || true
    break
  fi
  sleep 10
  COUNT=$((COUNT+1))
done

echo ">>> STAGE 7: WATCHER"
cat > /usr/local/bin/docker-compose-watcher.sh <<'WATCHER'
#!/bin/bash
set -euo pipefail

TARGET_DIR="/home/ec2-user/ghostfolio"
FILE_NAME="docker-compose.yml"

mkdir -p "$TARGET_DIR"
ln -sf /home/ec2-user/.env.infra "$TARGET_DIR/.env"

while [ ! -f "$TARGET_DIR/$FILE_NAME" ]; do
  sleep 3
done

while true; do
  inotifywait -e close_write "$TARGET_DIR/$FILE_NAME"
  cd "$TARGET_DIR"

  aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 170934847890.dkr.ecr.us-east-1.amazonaws.com

  ln -sf /home/ec2-user/.env.infra "$TARGET_DIR/.env"
  docker compose pull
  docker compose up -d
done
WATCHER
chmod +x /usr/local/bin/docker-compose-watcher.sh

cat > /etc/systemd/system/docker-watcher.service <<'SERVICE'
[Unit]
Description=Docker Watcher
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/docker-compose-watcher.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE
systemctl daemon-reload
systemctl enable --now docker-watcher.service

echo ">>> STAGE 8: BACKUP"
cat > /usr/local/bin/db_backup.sh <<EOF
#!/bin/bash
set -euo pipefail

TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="ghostfolio_db_\$TIMESTAMP.sql"
BACKUP_PATH="/tmp/\$BACKUP_NAME"
S3_PATH="s3://${s3_bucket_name}/backups/\$BACKUP_NAME"

cd /home/ec2-user/ghostfolio
docker compose exec -T postgres pg_dump -U root ghostfolio > "\$BACKUP_PATH"
aws s3 cp "\$BACKUP_PATH" "\$S3_PATH"
rm -f "\$BACKUP_PATH"
EOF

chmod +x /usr/local/bin/db_backup.sh
echo "0 3 * * * /usr/local/bin/db_backup.sh >> /var/log/backup.log 2>&1" | crontab -

echo "Setup Complete!"

rm -f /var/lib/cloud/instance/user-data.txt
rm -f /var/lib/cloud/instance/scripts/part-001
