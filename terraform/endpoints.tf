# ============================================================
# VPC endpoints for private app nodes
# ============================================================

locals {
  interface_vpc_endpoints = {
    ec2     = "com.amazonaws.${var.region}.ec2"
    ecr_api = "com.amazonaws.${var.region}.ecr.api"
    ecr_dkr = "com.amazonaws.${var.region}.ecr.dkr"
    logs    = "com.amazonaws.${var.region}.logs"
    sts     = "com.amazonaws.${var.region}.sts"
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.cluster_name}-vpc-endpoints"
  description = "Allow private nodes to access AWS interface endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-vpc-endpoints-sg" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_vpc_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids = [
    aws_subnet.cp_az1.id,
    aws_subnet.cp_az2.id,
  ]
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  tags = { Name = "${var.cluster_name}-${each.key}-endpoint" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.app.id,
    aws_route_table.proxy_public.id,
    aws_route_table.cp.id,
  ]

  tags = { Name = "${var.cluster_name}-s3-endpoint" }
}
