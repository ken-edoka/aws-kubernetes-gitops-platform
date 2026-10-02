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