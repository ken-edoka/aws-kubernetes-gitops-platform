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