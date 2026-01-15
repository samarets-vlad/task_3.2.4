data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "web" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2.micro" 

  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  
  
  associate_public_ip_address = true

  tags = {
    Name = "HelloWorld"
  }

user_data = <<-EOF
#!/bin/bash
# 1. Обновление и установка Nginx
sudo yum update -y
sudo amazon-linux-extras install nginx1 -y 
sudo systemctl enable nginx
sudo systemctl start nginx

# 2. Установка  SSL
sudo amazon-linux-extras install epel -y
sudo yum install certbot python-certbot-nginx -y
# Получаем сертификат (Nginx пока настроится автоматически)
sudo certbot --nginx --non-interactive --agree-tos --email admin@${var.domain_name} -d ${var.domain_name}

# 3. Установка Docker и Docker Compose
sudo amazon-linux-extras install docker -y
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -a -G docker ec2-user
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo yum install git -y

# 4. Скачивание и запуск Ghostfolio
cd /home/ec2-user
git clone https://github.com/ghostfolio/ghostfolio.git
cd ghostfolio
cp .env.example .env
# Запуск в фоновом режиме на порту 3333
/usr/local/bin/docker-compose -f docker/docker-compose.yml up -d

# 5. [ВАЖНО] Настройка Nginx как Reverse Proxy
cat <<EOC > /etc/nginx/conf.d/ghostfolio.conf
server {
    listen 443 ssl;
    server_name ${var.domain_name};

    ssl_certificate /etc/letsencrypt/live/${var.domain_name}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${var.domain_name}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3333;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
server {
    listen 80;
    server_name ${var.domain_name};
    return 301 https://\$host\$request_uri;
}
EOC

# Перезагружаем Nginx
sudo systemctl restart nginx
  EOF
}

resource "aws_eip" "web_ip" {
  count    = var.enable_eip ? 1 : 0
  instance = aws_instance.web.id
  domain   = "vpc"
}