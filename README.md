# Tự làm outbound proxy cho EKS trên AWS Local Zone

AWS Local Zone là phần mở rộng của một AWS Region, đặt gần một khu vực địa lý cụ thể hơn. Mục tiêu là đưa compute, storage và một số managed services tới gần user hoặc hệ thống on-prem để giảm latency.

Nhưng Local Zone không đầy đủ như parent region. Một hạn chế rất dễ đụng khi thiết kế network là **không có NAT Gateway trong Local Zone**. Nếu app workloads nằm private subnet, không public IP, nhưng vẫn cần gọi Partner API bằng fixed source IP thì phải có hướng thay thế.

Lab này dùng **Squid forward proxy trên EKS** để xử lý outbound traffic từ private app nodes.

## Bài toán

Trong môi trường doanh nghiệp, app nodes thường không nên public. Workload nên nằm trong private subnet, không public IP và không có internet trực tiếp.

Nhưng app vẫn cần đi ra Internet hoặc gọi Partner API bằng fixed source IP, đồng thời chặn các domain không nằm trong whitelist.

Ở region bình thường, cách quen thuộc là đi qua NAT Gateway. Ở Local Zone không có NAT Gateway, nên lab này dùng hướng gần giống NAT instance, nhưng thay bằng Squid forward proxy để kiểm soát outbound ở mức domain.

## Ý tưởng

```text
App Pod trên private app node
  -> HTTP_PROXY / HTTPS_PROXY
  -> Squid ClusterIP Service trong EKS
  -> Squid Pod trên proxy node
  -> Elastic IP của proxy node
  -> Internet Gateway
  -> Partner APIs
```

App pod không đi thẳng ra Internet Gateway. Toàn bộ outbound phải qua Squid service rồi ra ngoài bằng EIP của proxy node.

## Kiến trúc

![Squid Outbound Proxy Architecture](docs/architecture.png)

```text
AWS Region: ap-southeast-2
VPC: 10.0.0.0/16

EKS Control Plane
  - ap-southeast-2a
  - ap-southeast-2b

AWS Local Zone: ap-southeast-2-per-1a

Private App Subnet: 10.0.10.0/24
  - App Node 1: no public IP
  - App Node 2: no public IP
  - App Pods use HTTP_PROXY / HTTPS_PROXY

Public Proxy Subnet: 10.0.40.0/24
  - Proxy Node 1: Squid Pod + EIP
  - Proxy Node 2: Squid Pod + EIP
  - Route 0.0.0.0/0 -> Internet Gateway
```

## Thành phần chính

| Thành phần | Vai trò |
| --- | --- |
| Private app nodes | Chạy application workloads, không có public IP |
| Public proxy nodes | Chạy Squid proxy, có route ra Internet Gateway |
| Elastic IP | Fixed source IP để partner whitelist |
| Squid DaemonSet | Mỗi proxy node có một Squid pod |
| ClusterIP Service | App pods gọi proxy bằng DNS nội bộ |
| Squid ACL | Chỉ allow domain trong whitelist |
| VPC endpoints | Giúp private app nodes bootstrap/pull image mà không cần NAT Gateway |
| Lambda EIP manager | Tự gắn EIP còn trống vào proxy node khi node được tạo lại |

## Cấu trúc repo

```text
squid-outbound-proxy/
├── terraform/
│   ├── main.tf        # Providers
│   ├── vpc.tf         # VPC, subnets, route tables, IGW
│   ├── endpoints.tf   # VPC endpoints cho private app nodes
│   ├── eks.tf         # EKS cluster và managed node groups
│   ├── eip.tf         # EIP trong Local Zone + Lambda EIP manager
│   ├── squid.tf       # Helm release cho Squid
│   └── outputs.tf
├── helm/
│   └── squid-proxy/   # Squid DaemonSet, ConfigMap, ClusterIP Service
├── k8s/
│   └── kustomization.yaml
└── docs/
    └── architecture.png
```

## Thực hiện

### 1. VPC và subnet

Tạo một private subnet cho app nodes và một public subnet cho proxy nodes trong Local Zone.

```hcl
resource "aws_subnet" "app" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.app_subnet_cidr
  availability_zone = var.local_zone
}

resource "aws_subnet" "proxy" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.proxy_subnet_cidr
  availability_zone       = var.local_zone
  map_public_ip_on_launch = true
}

resource "aws_route_table" "proxy_public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}
```

App subnet không có default route ra Internet Gateway. Đây là điểm quan trọng để giữ app nodes đúng mô hình private.

### 2. VPC endpoints cho private nodes

App nodes nằm private subnet nên cần VPC endpoints để bootstrap EKS, pull image từ ECR và ghi log mà không cần NAT Gateway.

```hcl
locals {
  interface_vpc_endpoints = {
    ec2     = "com.amazonaws.${var.region}.ec2"
    ecr_api = "com.amazonaws.${var.region}.ecr.api"
    ecr_dkr = "com.amazonaws.${var.region}.ecr.dkr"
    logs    = "com.amazonaws.${var.region}.logs"
    sts     = "com.amazonaws.${var.region}.sts"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.interface_vpc_endpoints
  vpc_id              = aws_vpc.main.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
}
```

### 3. EKS node groups

Tách worker nodes thành hai nhóm rõ vai trò:

```hcl
eks_managed_node_groups = {
  app_nodes = {
    subnet_ids     = [aws_subnet.app.id]
    instance_types = [var.app_node_instance_type]
    desired_size   = 2

    labels = {
      "node-role" = "app-node"
    }
  }

  proxy_nodes = {
    subnet_ids     = [aws_subnet.proxy.id]
    instance_types = [var.proxy_node_instance_type]
    desired_size   = var.eip_count

    labels = {
      "node-role" = "proxy-node"
    }

    taints = [{
      key    = "proxy-only"
      value  = "true"
      effect = "NO_SCHEDULE"
    }]
  }
}
```

App workloads chỉ chạy trên `app-node`. Squid chỉ chạy trên `proxy-node`.

### 4. Elastic IP đúng Local Zone

Mỗi proxy node cần một Elastic IP cố định để partner whitelist. EIP phải được cấp đúng network border group của Local Zone.

```hcl
locals {
  local_zone_network_border_group = replace(var.local_zone, "/[a-z]$/", "")
}

resource "aws_eip" "proxy_worker" {
  count = var.eip_count

  domain               = "vpc"
  network_border_group = local.local_zone_network_border_group

  tags = {
    Role    = "squid-outbound"
    Cluster = var.cluster_name
  }
}
```

Nếu dùng EIP mặc định ở parent region, EC2 trong Local Zone sẽ không associate được EIP.

### 5. Auto-assign EIP cho proxy nodes

EIP được reserve trước, nhưng EKS managed node group có thể recreate EC2. Lambda sẽ gắn EIP còn trống vào proxy node khi instance chuyển sang `running`.

```hcl
resource "aws_lambda_function" "eip_manager" {
  function_name = "${var.cluster_name}-eip-manager"

  environment {
    variables = {
      EIP_ALLOCATION_IDS = join(",", aws_eip.proxy_worker[*].allocation_id)
      CLUSTER_NAME       = var.cluster_name
    }
  }
}

resource "aws_cloudwatch_event_rule" "ec2_state_change" {
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail      = { state = ["running", "terminated"] }
  })
}
```

Lambda chỉ xử lý instance có tag `proxy-node=true`, tránh gắn EIP nhầm sang app node.

### 6. Squid DaemonSet và ClusterIP service

Squid chạy dạng DaemonSet trên proxy nodes:

```yaml
hostNetwork: true
dnsPolicy: ClusterFirstWithHostNet

ports:
  - containerPort: 3128
    hostPort: 3128

nodeSelector:
  node-role: proxy-node

tolerations:
  - key: proxy-only
    operator: Equal
    value: "true"
    effect: NoSchedule

service:
  type: ClusterIP
  port: 3128
```

`hostNetwork` và `hostPort` là điểm quan trọng: Squid dùng network stack của node, nên outbound traffic đi ra bằng EIP của proxy node.

### 7. Domain whitelist

Domain được quản lý bằng Terraform variable rồi truyền vào Helm chart để render thành Squid ACL.

```hcl
variable "partner_domains" {
  description = "Domain partner được phép đi qua Squid"
  type        = list(string)
  default = [
    "ifconfig.me",
  ]
}
```

Squid ACL:

```text
http_access allow localnet allowed_partners
http_access deny all
```

Domain không nằm trong whitelist sẽ bị Squid trả `403`.

### 8. App workload dùng proxy

App workload chỉ cần cấu hình proxy env:

```yaml
env:
  - name: HTTP_PROXY
    value: http://squid-proxy.squid.svc.cluster.local:3128
  - name: HTTPS_PROXY
    value: http://squid-proxy.squid.svc.cluster.local:3128
  - name: NO_PROXY
    value: localhost,127.0.0.1,10.0.0.0/8,.cluster.local,.svc
```

## Deploy

```bash
cd terraform
terraform init
terraform plan -var="aws_profile=<YOUR_PROFILE>"
terraform apply -var="aws_profile=<YOUR_PROFILE>"
```

Lấy thông tin sau deploy:

```bash
terraform output cluster_name
terraform output proxy_eips
terraform output squid_service_dns
```

## Test

Cập nhật kubeconfig:

```bash
aws eks update-kubeconfig \
  --name frt-outbound-proxy \
  --region ap-southeast-2 \
  --profile <YOUR_PROFILE>
```

Tạo test pod trên app node private:

```bash
kubectl run curl-test \
  --image=curlimages/curl \
  --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"node-role":"app-node"},"containers":[{"name":"curl-test","image":"curlimages/curl","command":["sleep","3600"]}]}}'
```

Test app pod không có internet trực tiếp:

```bash
kubectl exec curl-test -- \
  curl -m 5 -sS http://ifconfig.me/ip
```

Test đi qua Squid:

```bash
kubectl exec curl-test -- \
  curl -sS \
  -x http://squid-proxy.squid.svc.cluster.local:3128 \
  http://ifconfig.me/ip
```

Kết quả mong muốn: trả về một trong các EIP của proxy node.

Test domain bị chặn:

```bash
kubectl exec curl-test -- \
  curl -sS \
  -x http://squid-proxy.squid.svc.cluster.local:3128 \
  http://google.com
```

Kết quả mong muốn: Squid trả `ERR_ACCESS_DENIED`.

Lọc log liên quan tới lab:

```bash
kubectl logs -n squid -l app.kubernetes.io/name=squid-proxy --tail=200 | \
  grep -E 'ifconfig.me|google.com|TCP_DENIED|TCP_TUNNEL|TCP_MISS'
```

- `curl-test` chạy trên app node private `10.0.10.246`, không có external IP.
- Hai Squid pods chạy trên proxy nodes `10.0.40.46` và `10.0.40.90`.
- Request tới `ifconfig.me` qua proxy trả về EIP của proxy node.
- Request tới `google.com` bị `TCP_DENIED`.

## Destroy

```bash
cd terraform
terraform destroy -var="aws_profile=<YOUR_PROFILE>"
```

## Điểm nổi bật để đưa vào CV

- Thiết kế outbound network cho EKS workloads trên AWS Local Zone khi không có NAT Gateway.
- Tách app node group private và proxy node group public theo đúng mô hình doanh nghiệp.
- Dùng VPC endpoints để private nodes bootstrap/pull image mà không cần internet trực tiếp.
- Dùng Squid DaemonSet, ClusterIP service và HTTP_PROXY/HTTPS_PROXY để ép app traffic đi qua proxy.
- Dùng Elastic IP theo đúng Local Zone network border group để có fixed source IP cho partner whitelist.
- Tự động gắn/release EIP cho proxy nodes bằng Lambda và EventBridge.
- Kiểm soát outbound domain bằng Squid ACL và xác minh bằng log thực tế.

## Blog

Chi tiết bài viết: [Tự làm NAT Gateway trên AWS Local Zone bằng Squid + EIP](https://toannd021104.github.io/devops-blog)
