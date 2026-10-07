locals {
  name = "kops-utility"
}
# Create a default VPC for vault server
resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/16" # CIDR block for the VPC
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "${local.name}-vpc"
  }
}

# Generate a new RSA private key using the TLS provider
resource "tls_private_key" "keypair" {
  algorithm = "RSA"
  rsa_bits  = 4096

}
# Create a new key pair using the AWS provider
resource "aws_key_pair" "public_key" {
  key_name   = "${local.name}-keypairj"
  public_key = tls_private_key.keypair.public_key_openssh
}

# Save the generated private key to a local PEM file
resource "local_file" "private_key" {
  content  = tls_private_key.keypair.private_key_pem
  filename = "${local.name}-keypair.pem"
}

# data source to fetch avaiable availability zones in the region
data "aws_availability_zones" "available" {
  state = "available"
}

# Create a public subnet in the VPC
resource "aws_subnet" "public_subnet" {
  count                   = 2 # Create two public subnets
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = "10.0.${count.index}.0/24"                                        # CIDR block for each subnet
  availability_zone       = element(data.aws_availability_zones.available.names, count.index) # Use different AZs
  map_public_ip_on_launch = true                                                              # Enable public IP assignment
  tags = {
    Name = "${local.name}-public-subnet-${count.index + 1}"
  }
}
# Create an Internet Gateway for the VPC
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "${local.name}-internet-gateway"
  }
}

# Create a route table for the public subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
    Name = "${local.name}-public-rt"
  }
}
# Associate the public subnets with the route table
resource "aws_route_table_association" "public_assoc" {
  count          = 2
  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.public.id
}

# IAM role for Jenkins EC2 instance
resource "aws_iam_role" "instance_role" {
  name               = "${local.name}-Jenkins-role2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Attach SSM policies to Jenkins role
resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Attach Administrator access policy to Jenkins role
resource "aws_iam_role_policy_attachment" "admin_attach" {
  role       = aws_iam_role.instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Attach role to Jenkins instance profile
resource "aws_iam_instance_profile" "jenkins_instance_profile" {
  name = "${local.name}-Jenkins-profile2"
  role = aws_iam_role.instance_role.name

}

#Security group for jenkins
resource "aws_security_group" "jenkins_sg" {
  name        = "${local.name}-jenkins-sg"
  description = "Allowing inbound traffic"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description     = "Jenkins-port"
    protocol        = "tcp"
    from_port       = 8080
    to_port         = 8080
    security_groups = [aws_security_group.jenkins_elb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-jenkins-sg"
  }
}

#Security group for jenkins-elb
resource "aws_security_group" "jenkins_elb_sg" {
  name        = "${local.name}-jenkins-elb-sg"
  description = "Allowing inbound traffic"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    description = "Jenkins access"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name}-jenkins-elb-sg"
  }
}

# Get the latest RHEL 9 AMI for eu-west-1 (Red Hat official account)
data "aws_ami" "redhat" {
  most_recent = true
  owners      = ["309956199498"] # Red Hat official AWS account
  filter {
    name   = "name"
    values = ["RHEL-8.*_HVM-*-x86_64-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# instance and installing jenkins
resource "aws_instance" "jenkins" {
  ami                         = data.aws_ami.redhat.id
  instance_type               = "t2.large"
  subnet_id                   = aws_subnet.public_subnet[1].id
  key_name                    = aws_key_pair.public_key.key_name
  vpc_security_group_ids      = [aws_security_group.jenkins_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins_instance_profile.name
  associate_public_ip_address = true
  user_data = templatefile("${path.module}/jenkins.sh", {
    newrelic_api_key    = var.newrelic_api_key
    newrelic_account_id = var.newrelic_account_id
    region              = var.region
  })
  root_block_device {
    volume_size = 100
    volume_type = "gp3"
    encrypted   = true
  }
  tags = {
    Name = "${local.name}-jenkins"
  }
}
#creating Jenkins elb
resource "aws_elb" "elb-jenkins" {
  name            = "${local.name}-elb-jenkins"
  security_groups = [aws_security_group.jenkins_elb_sg.id]
  subnets         = aws_subnet.public_subnet[*].id

  listener {
    instance_port      = 8080
    instance_protocol  = "http"
    lb_port            = 443
    lb_protocol        = "https"
    ssl_certificate_id = aws_acm_certificate.acm-cert.arn
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 29
    target              = "tcp:8080"
    interval            = 30
  }

  instances                   = [aws_instance.jenkins.id]
  cross_zone_load_balancing   = true
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400

  tags = {
    Name = "${local.name}-elb-jenkins"
  }
}


# Lookup the existing Route 53 hosted zone
data "aws_route53_zone" "my-hosted-zone" {
  name         = var.domain_name
  private_zone = false
}

# Create ACM certificate with DNS validation
resource "aws_acm_certificate" "acm-cert" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name}-acm-cert"
  }
}

# fetch DNS validation records for the ACM certificate
resource "aws_route53_record" "acm_validation_records" {
  for_each = {
    for dvo in aws_acm_certificate.acm-cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.my-hosted-zone.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

# Validate the ACM certificate after DNS records are created
resource "aws_acm_certificate_validation" "acm_cert_validation" {
  certificate_arn         = aws_acm_certificate.acm-cert.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation_records : r.fqdn]
}

#creating A jenkins record
resource "aws_route53_record" "jenkins-record" {
  zone_id = data.aws_route53_zone.my-hosted-zone.zone_id
  name    = "jenkins.${var.domain_name}"
  type    = "A"
  alias {
    name                   = aws_elb.elb-jenkins.dns_name
    zone_id                = aws_elb.elb-jenkins.zone_id
    evaluate_target_health = true
  }
}