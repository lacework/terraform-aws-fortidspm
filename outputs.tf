output "instance_id" {
  description = "EC2 instance ID running scan_engine. Reference this when contacting Fortinet support."
  value       = aws_instance.scan_engine.id
}

output "private_ip" {
  description = "Private IP of the scan_engine EC2 instance."
  value       = aws_instance.scan_engine.private_ip
}

output "public_ip" {
  description = "Public IP of the scan_engine EC2 instance (empty when enable_public_ip = false; outbound-only via NAT is the default)."
  value       = var.enable_public_ip ? aws_instance.scan_engine.public_ip : ""
}

output "vpc_id" {
  description = "ID of the VPC this module created for scan_engine."
  value       = aws_vpc.main.id
}

output "nat_gateway_public_ip" {
  description = "Public IP (EIP) of the NAT gateway — the source IP of all scan_engine outbound traffic. Give this to Fortinet if an egress allowlist is needed."
  value       = aws_eip.nat.public_ip
}

output "iam_role_arn" {
  description = "IAM role ARN attached to scan_engine. scan_engine assumes this role at runtime via IMDSv2 to read your S3 buckets."
  value       = aws_iam_role.scan_engine.arn
}

output "iam_role_name" {
  description = "IAM role name (useful if you want to attach extra policies)."
  value       = aws_iam_role.scan_engine.name
}

output "security_group_id" {
  description = "Security group ID controlling scan_engine egress."
  value       = aws_security_group.scan_engine.id
}