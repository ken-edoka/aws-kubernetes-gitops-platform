locals {
  name = "kops"
}
 
# IAM Role for SSM
resource "aws_iam_role" "ssm_role" {
  name = "${local.name}-ssm-role1"
 
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}
 
resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
 
 
resource "aws_iam_role_policy_attachment" "s3_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}
 
 
resource "aws_iam_role_policy_attachment" "ec2_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}
 
 
resource "aws_iam_role_policy_attachment" "route53_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
}
 
 
resource "aws_iam_role_policy_attachment" "iam_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/IAMFullAccess"
}
 
 
resource "aws_iam_role_policy_attachment" "vpc_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonVPCFullAccess"
}
 
resource "aws_iam_role_policy_attachment" "eventbridge_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEventBridgeFullAccess"
}
 
resource "aws_iam_role_policy_attachment" "sqs_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
}
 
resource "aws_iam_role_policy" "bootstrap_read_access" {
  name = "${local.name}-bootstrap-read-access"
  role = aws_iam_role.ssm_role.id
 
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "acm:ListCertificates",
          "acm:DescribeCertificate",
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "elasticloadbalancing:DescribeLoadBalancers",
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
        ],
        Resource = "*"
      }
    ]
  })
}
 
resource "aws_secretsmanager_secret" "github_credentials" {
  name                    = "${local.name}-github-credentials"
  recovery_window_in_days = 0
 
  tags = {
    Name = "${local.name}-github-credentials"
  }
}
 
resource "aws_secretsmanager_secret_version" "github_credentials" {
  secret_id = aws_secretsmanager_secret.github_credentials.id
  secret_string = jsonencode({
    username = var.github_username
    password = var.github_password
  })
}
resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${local.name}-ssm-profile1"
  role = aws_iam_role.ssm_role.name
}
 
# this block creates keypair
resource "tls_private_key" "key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
 
resource "local_file" "private_key" {
  content         = tls_private_key.key.private_key_pem
  filename        = "${local.name}-key.pem"
  file_permission = "640"
}
 
resource "aws_key_pair" "public_key" {
  key_name   = "${local.name}-public_key"
  public_key = tls_private_key.key.public_key_openssh
}
 
# Security Group (no SSH access)
resource "aws_security_group" "kops_sg" {
  name        = "${local.name}-sg"
  description = "Allow all egress traffic only"
  vpc_id      = data.aws_vpc.existing.id
 
  # No ingress rules — no SSH access
 
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  tags = {
    Name = "${local.name}-sg"
  }
}
 
data "aws_vpc" "existing" {
  tags = var.vpc_tags
}
 
data "aws_subnet" "existing" {
  vpc_id = data.aws_vpc.existing.id
  tags   = var.subnet_tags
}
 
# Data source to get the latest Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
# EC2 Instance for Kops Admin (SSM only)
resource "aws_instance" "kops_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.medium"
  subnet_id                   = data.aws_subnet.existing.id
  vpc_security_group_ids      = [aws_security_group.kops_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  key_name                    = aws_key_pair.public_key.key_name
  associate_public_ip_address = true
  user_data_base64            = base64gzip(local.user_data)
  user_data_replace_on_change = true
 
  tags = {
    Name = "${local.name}-admin-server"
  }
}
 
data "aws_route53_zone" "main" {
  name         = ""
  private_zone = false
}
 
# Route53 A Record for Kops Admin Server
resource "aws_route53_record" "kops_dns" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "kops.${data.aws_route53_zone.main.name}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.kops_server.public_ip]
}