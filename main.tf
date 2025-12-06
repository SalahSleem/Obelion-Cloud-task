provider "aws" {
  region = "us-east-1"
}

##############################################
# 1) VPC
##############################################
resource "aws_vpc" "task_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "task"
  }
}

##############################################
# 2) Internet Gateway
##############################################
resource "aws_internet_gateway" "task_igw" {
  vpc_id = aws_vpc.task_vpc.id

  tags = {
    Name = "task-igw"
  }
}

##############################################
# 3) Public Subnets (adjusted CIDRs to avoid conflicts)
##############################################
resource "aws_subnet" "task_public_subnet_a" {
  vpc_id                  = aws_vpc.task_vpc.id
  cidr_block              = "10.0.5.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "task-public-subnet-a"
  }
}

resource "aws_subnet" "task_public_subnet_b" {
  vpc_id                  = aws_vpc.task_vpc.id
  cidr_block              = "10.0.7.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "task-public-subnet-b"
  }
}

##############################################
# 4) Private Subnets (adjusted CIDRs)
##############################################
resource "aws_subnet" "task_private_subnet_a" {
  vpc_id            = aws_vpc.task_vpc.id
  cidr_block        = "10.0.6.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name = "task-private-subnet-a"
  }
}

resource "aws_subnet" "task_private_subnet_b" {
  vpc_id            = aws_vpc.task_vpc.id
  cidr_block        = "10.0.8.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name = "task-private-subnet-b"
  }
}

##############################################
# 5) Public Route Table
##############################################
resource "aws_route_table" "task_public_rt" {
  vpc_id = aws_vpc.task_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.task_igw.id
  }

  tags = {
    Name = "task-public-rt"
  }
}

resource "aws_route_table_association" "task_public_assoc_a" {
  subnet_id      = aws_subnet.task_public_subnet_a.id
  route_table_id = aws_route_table.task_public_rt.id
}

resource "aws_route_table_association" "task_public_assoc_b" {
  subnet_id      = aws_subnet.task_public_subnet_b.id
  route_table_id = aws_route_table.task_public_rt.id
}

##############################################
# 6) Security Groups
##############################################
resource "aws_security_group" "public_sg" {
  name   = "task-public-sg"
  vpc_id = aws_vpc.task_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "public-sg"
  }
}

resource "aws_security_group" "rds_sg" {
  name   = "task-rds-sg"
  vpc_id = aws_vpc.task_vpc.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.public_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "task-rds-sg"
  }
}

##############################################
# 7) Ubuntu 22.04 AMI
##############################################
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  owners = ["099720109477"]
}

##############################################
# 8) SSH Key Pair
##############################################
resource "aws_key_pair" "task_key" {
  key_name   = "task-ssh-key"
  public_key = file("/KEY/mykey.pub")  # Update to your path
}

##############################################
# 9) IAM Role for EC2 (to access Secrets Manager)
##############################################
resource "aws_iam_role" "ec2_secrets_role" {
  name = "task-ec2-secrets-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "secrets_policy" {
  name = "task-secrets-policy"
  role = aws_iam_role.ec2_secrets_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "secretsmanager:GetSecretValue"
        Effect   = "Allow"
        Resource = data.aws_secretsmanager_secret.rds_secret.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "task-ec2-profile"
  role = aws_iam_role.ec2_secrets_role.name
}

##############################################
# 10) Backend EC2
##############################################
resource "aws_instance" "backend" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.task_public_subnet_a.id
  vpc_security_group_ids      = [aws_security_group.public_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.task_key.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -e

    apt update -y
    apt install -y git php php-xml php-mbstring php-curl php-zip php-mysql composer nginx php8.1-fpm awscli jq

    # Configure Nginx for Laravel
    cat > /etc/nginx/sites-available/laravel <<'INNER_EOF'
    server {
        listen 80;
        server_name _;
        root /var/www/backend/public;
        index index.php index.html index.htm;

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location ~ \.php$ {
            include snippets/fastcgi-php.conf;
            fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
        }

        location ~ /\.ht {
            deny all;
        }
    }
    INNER_EOF

    ln -s /etc/nginx/sites-available/laravel /etc/nginx/sites-enabled/
    rm /etc/nginx/sites-enabled/default
    #systemctl enable nginx
    #systemctl start nginx
    systemctl enable php8.1-fpm
    systemctl start php8.1-fpm

    mkdir -p /var/www/backend
    chown -R ubuntu:ubuntu /var/www/backend
  EOF

  root_block_device {
    volume_size = 8
  }

  tags = {
    Name = "task-backend"
  }
}

##############################################
# 11) Frontend EC2
##############################################
resource "aws_instance" "frontend" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.task_public_subnet_b.id
  vpc_security_group_ids      = [aws_security_group.public_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.task_key.key_name
  # iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
    #!/bin/bash
    set -e

    apt update -y
    apt install -y git docker.io docker-compose

    systemctl enable docker
    systemctl start docker
    usermod -aG docker ubuntu

    mkdir -p /var/www/frontend
    chown ubuntu:ubuntu /var/www/frontend
  EOF

  root_block_device {
    volume_size = 8
  }

  tags = {
    Name = "task-frontend"
  }
}

##############################################
# 12) Load Secret from AWS Secrets Manager
##############################################
data "aws_secretsmanager_secret" "rds_secret" {
  name = "task/rds/creds"
}

data "aws_secretsmanager_secret_version" "rds_secret_value" {
  secret_id = data.aws_secretsmanager_secret.rds_secret.id
}

locals {
  rds_creds = jsondecode(data.aws_secretsmanager_secret_version.rds_secret_value.secret_string)
}

##############################################
# 13) RDS Subnet Group
##############################################
resource "aws_db_subnet_group" "task_rds_subnets" {
  name       = "task-rds-subnet-group"
  subnet_ids = [aws_subnet.task_private_subnet_a.id, aws_subnet.task_private_subnet_b.id]

  tags = {
    Name = "task-rds-subnet-group"
  }
}

##############################################
# 14) RDS MySQL 8
##############################################
resource "aws_db_instance" "task_mysql" {
  identifier             = "task-mysql"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = "taskdb"

  username               = local.rds_creds.username
  password               = local.rds_creds.password

  skip_final_snapshot    = true
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.task_rds_subnets.name

  tags = {
    Name = "task-mysql"
  }
}

############################################################
# 15) SNS Topic for Email Alerts
############################################################
resource "aws_sns_topic" "cpu_alerts_topic" {
  name = "task-cpu-alerts"
}

############################################################
# 16) Email Notification Subscription
############################################################
resource "aws_sns_topic_subscription" "email_sub" {
  topic_arn = aws_sns_topic.cpu_alerts_topic.arn
  protocol  = "email"
  endpoint  = "salahsleem55s@gmail.com"  # REPLACE WITH YOUR REAL EMAIL
}

############################################################
# 17) CloudWatch CPU Alarm for Backend EC2
############################################################
resource "aws_cloudwatch_metric_alarm" "backend_cpu_alarm" {
  alarm_name          = "backend-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 50
  alarm_description   = "Backend CPU > 50%"
  alarm_actions       = [aws_sns_topic.cpu_alerts_topic.arn]

  dimensions = {
    InstanceId = aws_instance.backend.id
  }
}

############################################################
# 18) CloudWatch CPU Alarm for Frontend EC2
############################################################
resource "aws_cloudwatch_metric_alarm" "frontend_cpu_alarm" {
  alarm_name          = "frontend-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 50
  alarm_description   = "Frontend CPU > 50%"
  alarm_actions       = [aws_sns_topic.cpu_alerts_topic.arn]

  dimensions = {
    InstanceId = aws_instance.frontend.id
  }
}

##############################################
# Outputs
##############################################
output "backend_public_ip" {
  description = "Public IP of the Backend EC2 instance"
  value       = aws_instance.backend.public_ip
}

output "frontend_public_ip" {
  description = "Public IP of the Frontend EC2 instance"
  value       = aws_instance.frontend.public_ip
}

output "rds_endpoint" {
  description = "RDS MySQL endpoint"
  value       = aws_db_instance.task_mysql.endpoint
}

output "ssh_public_key" {
  description = "Public SSH key used for EC2 login"
  value       = aws_key_pair.task_key.public_key
}
