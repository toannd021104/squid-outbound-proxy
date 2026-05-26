variable "aws_profile" {
  description = "AWS CLI profile name"
  default     = "default"
}

variable "region" {
  description = "AWS Region (parent region — EKS Control Plane chạy ở đây)"
  default     = "ap-southeast-2"
}

variable "local_zone" {
  description = "AWS Local Zone AZ — worker nodes chạy ở đây"
  default     = "ap-southeast-2-per-1a"
}

variable "cluster_name" {
  default = "frt-outbound-proxy"
}

variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

# Subnets Local Zone
variable "app_subnet_cidr" {
  description = "Private subnet — App Workloads (Local Zone)"
  default     = "10.0.10.0/24"
}

variable "internal_services_subnet_cidr" {
  description = "Reserved private subnet for internal services or future load balancers (Local Zone)"
  default     = "10.0.20.0/24"
}

variable "proxy_subnet_cidr" {
  description = "Public subnet — Proxy Worker Nodes + EIP (Local Zone)"
  default     = "10.0.40.0/24"
}

variable "proxy_node_instance_type" {
  description = "Instance type cho proxy node — phải available ở Local Zone Hà Nội"
  # Local Zone Perth support: t3.medium, t3.large, r5.large, c5.large
  default = "t3.medium"
}

variable "app_node_instance_type" {
  description = "Instance type cho app node"
  default     = "t3.medium"
}

variable "eip_count" {
  description = "Số EIP reserve = số proxy worker node tối đa. Partner whitelist các IP này"
  default     = 2
}

variable "proxy_node_max" {
  description = "Max proxy node — phải bằng eip_count để không bao giờ thiếu EIP"
  default     = 2
}

variable "partner_domains" {
  description = "Domain partner được phép đi qua Squid — chỉ các domain này mới ra được internet"
  type        = list(string)
  default = [
    "ifconfig.me",
  ]
}
