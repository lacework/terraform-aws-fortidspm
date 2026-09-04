variable "activation_token" {
  description = "One-time JWT activation token signed by Fortinet's control_service, specific to THIS region's scan_engine. The appliance reads it from EC2 user-data on first boot and seeds /var/log/scan_engine/scan_engine_config.json. Single-use — request a fresh token from Fortinet if EC2 is rebuilt. Carries tenant_id, the WSS server URL, and the control_service URL as claims. Baked into the deployment bundle by Fortinet; you should not need to edit it."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.activation_token) > 20
    error_message = "activation_token looks too short to be a valid JWT."
  }
}

variable "aws_region" {
  description = "AWS region this module instance deploys into. Set by the root from the provider it passes in; used for the S3 gateway endpoint service name and messages."
  type        = string
}

variable "ami_id" {
  description = "BYOL AMI ID for this region. Fortinet bakes the correct AMI per region into the generated root main.tf and passes it here. AMI IDs are region-specific, so each region gets its own."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.ami_id))
    error_message = "ami_id must look like ami-xxxxxxxxxxxxxxxxx."
  }
}

variable "deployment_name" {
  description = "Human-readable storage-profile name this scan_engine belongs to. Baked whole into every resource's fortidspm:deployment_name tag; a sanitized, 15-char-capped form is used in resource names (replacing the old random suffix)."
  type        = string
}

variable "deployment_id" {
  description = "Storage-profile UUID this scan_engine belongs to. Baked whole into every resource's fortidspm:deployment_id tag; its first 8 chars go into resource names. Combined with the region, this makes names deterministic and unique per deployment, so re-deploying the same profile into the same account is rejected on the duplicate IAM role name."
  type        = string
}

variable "env_id" {
  description = "control_service environment id (ENV_ID). Added as the fortidspm:env_id tag on every resource for ops searchability. Empty = tag omitted."
  type        = string
  default     = ""
}

variable "enable_cloudtrail" {
  description = "Reserved: enable CloudTrail-based activity ingestion for this scan_engine. Not yet wired to any resource — currently a no-op placeholder threaded through for a future feature."
  type        = bool
  default     = false
}

variable "account_id" {
  description = "Optional AWS account ID guard. When set, terraform refuses to deploy unless the caller identity (aws_caller_identity) is in this account, so a bundle baked for one customer account cannot be applied against another. Empty = no guard. Fortinet bakes this into the bundle when the target account is known."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Networking
#
# This module always builds its own isolated VPC (one public subnet for the NAT
# gateway, one private subnet for the instance). It never reuses the customer's
# existing network, so it needs no VPC/subnet inputs — the customer cannot
# accidentally place scan_engine in a subnet without outbound internet. The VPC
# is standalone (no peering / transit gateway), so these CIDRs never collide
# with anything — even identical CIDRs across regions are fine, since each
# region is a separate, isolated VPC. The defaults are fine as-is.
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC this module creates. The VPC is isolated (no peering), so this never collides with other networks; the default is fine."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet (holds only the NAT gateway). Must be within vpc_cidr."
  type        = string
  default     = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet (holds the scan_engine instance when enable_public_ip is false). Must be within vpc_cidr."
  type        = string
  default     = "10.0.1.0/24"
}

variable "enable_public_ip" {
  description = "Debugging only. When true, the instance is placed in the public (IGW-routed) subnet and given a public IP so it is directly reachable. Trade-offs while on: outbound egresses via the instance's own public IP (not the NAT EIP), and S3 reads go via the IGW instead of the free S3 gateway endpoint. scan_engine needs outbound only, so this defaults to false; a public IP in the private subnet would not work (it routes via NAT, not the IGW), which is why the flag also moves the subnet."
  type        = bool
  default     = false
}

variable "office_ip" {
  description = "Source CIDR allowed inbound to TCP 22 and 443 for debugging (e.g. your office egress IP as 203.0.113.4/32). AWS security-group rules require CIDR notation, so append /32 for a single IP. Empty = no inbound rule (scan_engine needs no inbound for normal operation). Only reachable when enable_public_ip is also true."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for scan_engine. MUST be a Nitro-generation type (c5/m5/r5/c6i/m6i/r6i families or newer). Older Xen-generation types (m4/c4/c3/t2) do not boot correctly. Recommended at least m5.2xlarge (8 vCPU, 32 GiB) for production scanning workloads; c5.xlarge (4 vCPU, 8 GiB) is enough for activation smoke tests."
  type        = string
  default     = "m5.2xlarge"

  validation {
    condition     = can(regex("^(c5|m5|r5|c5n|c5d|m5d|r5d|c6i|m6i|r6i|c6a|m6a|r6a|c7i|m7i|r7i|t3|t3a)\\.[a-z0-9]+$", var.instance_type))
    error_message = "instance_type must be a Nitro-generation type (c5/m5/r5/c6i/m6i/r6i/t3/... families). Older Xen-generation types (m4/c4/c3/t2) do not boot the FortiData BYOL AMI correctly."
  }
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB. MUST be < 10 GiB until the appliance's HD_DATA_SIZE constant (migbase/include/fdisk.h) is raised — otherwise smit treats the disk as a 'data disk', the appliance can't find its boot partition, and drops into maintainer shell on startup. 8 GiB fits the ~6.4 GiB raw image with safety margin. Working storage is provided via the separate log_volume_size disk."
  type        = number
  default     = 8

  validation {
    condition     = var.root_volume_size < 10
    error_message = "root_volume_size must be < 10 GiB until the appliance HD_DATA_SIZE constant is raised. See cloud_deploy/scripts/build-byol-ami.sh and the BYOL e2e bugs notes (bug #6)."
  }
}

variable "root_volume_type" {
  description = "Root EBS volume type."
  type        = string
  default     = "gp3"
}

variable "log_volume_size" {
  description = "Size in GiB of the secondary EBS volume used as the appliance's /data log disk. The appliance refuses to boot without it (drops into maintainer shell). Default 30 GiB matches the on-prem data.vmdk default; raise for production where logs accumulate."
  type        = number
  default     = 30
}

variable "extra_tags" {
  description = "Additional tags to apply to all AWS resources created by this module."
  type        = map(string)
  default     = {}
}