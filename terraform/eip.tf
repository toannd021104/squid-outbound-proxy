# ============================================================
# EIP — Reserve cố định trước
# Partner whitelist các IP này
# ============================================================
locals {
  local_zone_network_border_group = replace(var.local_zone, "/[a-z]$/", "")
}

resource "aws_eip" "proxy_worker" {
  count = var.eip_count

  domain               = "vpc"
  network_border_group = local.local_zone_network_border_group

  tags = {
    Name    = "${var.cluster_name}-proxy-eip-${count.index}"
    Role    = "squid-outbound"
    Cluster = var.cluster_name
  }
}

# ============================================================
# Lambda — Auto-assign EIP khi node join, release khi terminate
# ============================================================
data "archive_file" "eip_manager_zip" {
  type        = "zip"
  output_path = "/tmp/eip_manager.zip"

  source {
    filename = "index.py"
    content  = <<-PYTHON
import boto3
import os
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, context):
    ec2          = boto3.client('ec2')
    detail       = event.get('detail', {})
    state        = detail.get('state')
    instance_id  = detail.get('instance-id')

    if not instance_id:
        logger.warning("No instance-id in event")
        return

    if state == 'running':
        # Lấy ENI primary của instance mới
        resp = ec2.describe_instances(InstanceIds=[instance_id])
        instance = resp['Reservations'][0]['Instances'][0]

        # Chỉ xử lý node trong proxy node group
        tags = {t['Key']: t['Value'] for t in instance.get('Tags', [])}
        if tags.get('proxy-node') != 'true':
            logger.info(f"Instance {instance_id} is not a proxy node, skipping")
            return

        eni_id = instance['NetworkInterfaces'][0]['NetworkInterfaceId']
        logger.info(f"New proxy node {instance_id}, ENI: {eni_id}")

        # Tìm EIP chưa được associate
        eip_ids = os.environ['EIP_ALLOCATION_IDS'].split(',')
        for alloc_id in eip_ids:
            alloc_id = alloc_id.strip()
            eips = ec2.describe_addresses(AllocationIds=[alloc_id])['Addresses']
            if not eips[0].get('AssociationId'):
                ec2.associate_address(
                    AllocationId=alloc_id,
                    NetworkInterfaceId=eni_id
                )
                logger.info(f"Assigned EIP {alloc_id} ({eips[0]['PublicIp']}) to {eni_id}")
                return

        logger.error("No free EIP available! Consider increasing eip_count.")

    elif state == 'terminated':
        # Disassociate EIP khi node bị terminate (scale in)
        addresses = ec2.describe_addresses(
            Filters=[{'Name': 'instance-id', 'Values': [instance_id]}]
        )['Addresses']

        for addr in addresses:
            if addr.get('AssociationId'):
                ec2.disassociate_address(AssociationId=addr['AssociationId'])
                logger.info(f"Released EIP {addr['PublicIp']} from instance {instance_id}")
PYTHON
  }
}

resource "aws_lambda_function" "eip_manager" {
  function_name    = "${var.cluster_name}-eip-manager"
  role             = aws_iam_role.lambda_eip.arn
  handler          = "index.handler"
  runtime          = "python3.11"
  timeout          = 60
  filename         = data.archive_file.eip_manager_zip.output_path
  source_code_hash = data.archive_file.eip_manager_zip.output_base64sha256

  environment {
    variables = {
      EIP_ALLOCATION_IDS = join(",", aws_eip.proxy_worker[*].allocation_id)
      CLUSTER_NAME       = var.cluster_name
    }
  }

  tags = { Name = "${var.cluster_name}-eip-manager" }
}

# EventBridge: trigger khi EC2 instance state thay đổi
resource "aws_cloudwatch_event_rule" "ec2_state_change" {
  name        = "${var.cluster_name}-ec2-state-change"
  description = "Trigger EIP assignment on proxy node state change"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state = ["running", "terminated"]
    }
  })
}

resource "aws_cloudwatch_event_target" "eip_lambda" {
  rule = aws_cloudwatch_event_rule.ec2_state_change.name
  arn  = aws_lambda_function.eip_manager.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.eip_manager.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ec2_state_change.arn
}

# ============================================================
# IAM Role cho Lambda
# ============================================================
resource "aws_iam_role" "lambda_eip" {
  name = "${var.cluster_name}-lambda-eip-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_eip_policy" {
  name = "${var.cluster_name}-lambda-eip-policy"
  role = aws_iam_role.lambda_eip.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageEIP"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAddresses",
          "ec2:AssociateAddress",
          "ec2:DisassociateAddress",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}
