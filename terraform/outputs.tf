output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "proxy_eips" {
  description = "Danh sách EIP cố định — gửi cho partner để whitelist"
  value       = aws_eip.proxy_worker[*].public_ip
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "app_subnet_id" {
  value = aws_subnet.app.id
}

output "proxy_subnet_id" {
  value = aws_subnet.proxy.id
}

output "squid_service_dns" {
  description = "ClusterIP service DNS for Squid - set as HTTP_PROXY/HTTPS_PROXY in app"
  value       = "http://squid-proxy.squid.svc.cluster.local:3128"
}
