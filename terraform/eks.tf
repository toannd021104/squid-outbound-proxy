# ============================================================
# EKS Cluster
# Control Plane → Region Sydney ap-southeast-2 (bắt buộc)
# Worker Nodes → Local Zone Perth ap-southeast-2-per-1a
# ============================================================
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.31"

  vpc_id = aws_vpc.main.id

  # CP phải ở Region chính — ít nhất 2 AZ
  subnet_ids = [
    aws_subnet.cp_az1.id,
    aws_subnet.cp_az2.id,
  ]

  cluster_endpoint_public_access = true

  cluster_endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true

  node_security_group_additional_rules = {
    ingress_squid_from_vpc = {
      description = "Allow app nodes and pods to reach Squid hostPort"
      protocol    = "tcp"
      from_port   = 3128
      to_port     = 3128
      type        = "ingress"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  # ============================================================
  # Node Group 1: Proxy Nodes (Squid)
  # Chạy ở Local Zone — public subnet — có EIP
  # hostNetwork=true → traffic ra ngoài mang EIP của node
  # ============================================================
  eks_managed_node_groups = {
    proxy_nodes = {
      name           = "proxy-nodes"
      instance_types = [var.proxy_node_instance_type]

      min_size     = 1
      max_size     = var.proxy_node_max
      desired_size = var.eip_count

      # Worker node ở Local Zone
      subnet_ids = [aws_subnet.proxy.id]

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_type = "gp2" # Local Zone Perth không support gp3
            volume_size = 20
          }
        }
      }

      labels = {
        "node-role" = "proxy-node"
      }

      taints = [{
        key    = "proxy-only"
        value  = "true"
        effect = "NO_SCHEDULE"
      }]

      # Tag để Lambda EIP manager nhận biết đây là proxy node
      tags = {
        "proxy-node"                                    = "true"
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
    }

    # ============================================================
    # Node Group 2: App Nodes
    # Chạy ở Local Zone trong private app subnet.
    # App outbound HTTP/HTTPS vẫn phải đi qua Squid bằng proxy env vars.
    # ============================================================
    app_nodes = {
      name           = "app-nodes"
      instance_types = [var.app_node_instance_type]

      min_size     = 1
      max_size     = 10
      desired_size = 2

      # Private app nodes dùng EKS private endpoint và VPC endpoints để bootstrap.
      # Traffic app pod vẫn đi qua Squid nhờ HTTP_PROXY env var
      subnet_ids = [aws_subnet.app.id]

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_type = "gp2" # Local Zone Perth không support gp3
            volume_size = 20
          }
        }
      }

      labels = {
        "node-role" = "app-node"
      }

      tags = {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
    }
  }

  tags = { Project = var.cluster_name }
}
