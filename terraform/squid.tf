# ============================================================
# Squid Forward Proxy — Deploy qua Helm chart
# ============================================================
resource "helm_release" "squid_proxy" {
  name             = "squid-proxy"
  chart            = "${path.module}/../helm/squid-proxy"
  namespace        = "squid"
  create_namespace = true
  timeout          = 600   # 10 phút — chờ NLB ready
  wait             = false  # Không chờ pod/svc ready, tránh timeout

  # Domain whitelist từ variables.tf
  dynamic "set" {
    for_each = toset(var.partner_domains)
    content {
      name  = "squid.allowedDomains[${index(var.partner_domains, set.value)}]"
      value = ".${set.value}"
    }
  }

  values = [
    yamlencode({
      nodeSelector = {
        "node-role" = "proxy-node"
      }
      tolerations = [{
        key      = "proxy-only"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      }]
    })
  ]

  depends_on = [module.eks]
}

# Security Group cho Squid
resource "aws_security_group" "squid" {
  name        = "${var.cluster_name}-squid"
  description = "Squid forward proxy"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "App pods to Squid"
    from_port   = 3128
    to_port     = 3128
    protocol    = "tcp"
    cidr_blocks = [var.app_subnet_cidr]
  }

  ingress {
    description = "NLB health check"
    from_port   = 3128
    to_port     = 3128
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Squid to Internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-squid-sg" }
}
