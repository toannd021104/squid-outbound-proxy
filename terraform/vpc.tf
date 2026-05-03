# ============================================================
# VPC
# ============================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.cluster_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

# ============================================================
# Subnets — Region (Sydney) cho EKS Control Plane
# EKS CP bắt buộc phải có ít nhất 2 AZ ở Region chính
# ============================================================
resource "aws_subnet" "cp_az1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.100.0/24"
  availability_zone = "${var.region}a"  # ap-southeast-2a

  tags = {
    Name                                        = "${var.cluster_name}-cp-az1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "cp_az2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.101.0/24"
  availability_zone = "${var.region}b"  # ap-southeast-2b

  tags = {
    Name                                        = "${var.cluster_name}-cp-az2"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ============================================================
# Subnets — Local Zone Perth (ap-southeast-2-per-1a)
# Worker nodes chạy tại đây
# ============================================================

# Private - App Workloads (10.0.10.0/24)
resource "aws_subnet" "app" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.app_subnet_cidr
  availability_zone = var.local_zone

  tags = {
    Name                                        = "${var.cluster_name}-app"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Private - Internal ALB/NLB (10.0.20.0/24)
resource "aws_subnet" "alb" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.alb_subnet_cidr
  availability_zone = var.local_zone

  tags = {
    Name                                        = "${var.cluster_name}-alb"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Public - Proxy Worker Nodes có EIP (10.0.40.0/24)
resource "aws_subnet" "proxy" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.proxy_subnet_cidr
  availability_zone       = var.local_zone
  map_public_ip_on_launch = true   # Cần bật để EKS managed node group hoạt động — EIP gắn đè lên sau bởi Lambda

  tags = {
    Name                                        = "${var.cluster_name}-proxy"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ============================================================
# Route Tables
# ============================================================

# CP subnets → IGW (cần để EKS CP giao tiếp)
resource "aws_route_table" "cp" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.cluster_name}-cp-rt" }
}

resource "aws_route_table_association" "cp_az1" {
  subnet_id      = aws_subnet.cp_az1.id
  route_table_id = aws_route_table.cp.id
}

resource "aws_route_table_association" "cp_az2" {
  subnet_id      = aws_subnet.cp_az2.id
  route_table_id = aws_route_table.cp.id
}

# Public proxy subnet → IGW
resource "aws_route_table" "proxy_public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.cluster_name}-proxy-rt" }
}

resource "aws_route_table_association" "proxy" {
  subnet_id      = aws_subnet.proxy.id
  route_table_id = aws_route_table.proxy_public.id
}

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-app-rt" }
}

resource "aws_route_table_association" "app" {
  subnet_id      = aws_subnet.app.id
  route_table_id = aws_route_table.app.id
}

# ALB subnet route table
resource "aws_route_table" "alb" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-alb-rt" }
}

resource "aws_route_table_association" "alb" {
  subnet_id      = aws_subnet.alb.id
  route_table_id = aws_route_table.alb.id
}
