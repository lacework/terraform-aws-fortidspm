# ---------------------------------------------------------------------------
# scan_engine module — one isolated scan_engine stack in a single AWS region.
#
# The region is var.region, set on every regional resource and data source
# (AWS provider >= 6.0 resource-level region). The root instantiates this module
# once per selected region, all sharing ONE aws provider, so a single
# `terraform apply` deploys every region in one state while terraform starts a
# single provider process instead of one per region (each costs ~300 MiB, which
# OOM-killed deployments of 20+ regions). When var.region is null the region
# falls back to the provider's, so roots written for v0.3.0 and earlier (one
# aliased provider per region) still apply once their aws constraint admits 6.x.
# ---------------------------------------------------------------------------

locals {
  region = coalesce(var.region, data.aws_region.current.region)

  integration = var.global ? {
    lacework_integration_guid = lacework_integration_aws_fortidspm.main[0].intg_guid
    deployment_id             = lacework_integration_aws_fortidspm.main[0].deployment_id
    deployment_name           = lacework_integration_aws_fortidspm.main[0].deployment_name
    env_id                    = lacework_integration_aws_fortidspm.main[0].env_id
    activation_tokens         = lacework_integration_aws_fortidspm.main[0].activation_tokens
    image_ids                 = lacework_integration_aws_fortidspm.main[0].image_ids
  } : var.global_module_reference

  activation_token = lookup(local.integration.activation_tokens, local.region, "")
  ami_id           = lookup(local.integration.image_ids, local.region, "")

  dep_name_clean = trim(replace(lower(local.integration.deployment_name), "/[^a-z0-9]+/", "-"), "-")
  dep_name_short = trim(substr(local.dep_name_clean, 0, 15), "-")
  dep_id_short   = substr(local.integration.deployment_id, 0, 8)
  name_suffix    = "${local.region}-${local.dep_name_short}-${local.dep_id_short}"

  common_tags = merge({
    "fortidspm:role"            = "scan_engine"
    "fortidspm:managed"         = "terraform"
    "fortidspm:deployment_name" = local.integration.deployment_name
    "fortidspm:deployment_id"   = local.integration.deployment_id
  }, local.integration.env_id != "" ? { "fortidspm:env_id" = local.integration.env_id } : {}, var.extra_tags)
}

# Fallback only: the region of the provider the root passed in.
data "aws_region" "current" {}

resource "lacework_integration_aws_fortidspm" "main" {
  count = var.global ? 1 : 0

  name       = var.lacework_integration_name
  account_id = var.account_id != "" ? var.account_id : data.aws_caller_identity.current.account_id
  regions    = var.regions

  lifecycle {
    precondition {
      condition     = length(var.regions) > 0
      error_message = "regions must list every region a scan engine is deployed in when global = true."
    }
  }
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Network — a self-contained, isolated VPC built fresh in the customer account.
#
# scan_engine is outbound-only (it never accepts inbound connections), so it
# gets NO public IP and lives in a private subnet. Outbound to Fortinet's
# control plane (control_service ALB + API Gateway WSS, both on the public
# internet) goes through a NAT gateway in a public subnet. Reads of the
# customer's S3 buckets are routed through a free S3 gateway endpoint so they
# bypass the NAT (no NAT data-processing charge on bulk scan traffic).
#
# Everything here is created by this module — the customer's existing network is
# never touched, so the bundle needs no VPC/subnet inputs. Single-AZ: one
# instance needs no cross-AZ HA.
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  region = local.region
  state  = "available"

  # Not Local or Wavelength Zones, which instance type offerings also list.
  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

# Which candidate instance types each AZ offers. Not every region has m5
# (ap-east-2, ap-southeast-5/6/7, mx-central-1), and not every AZ does
# (use1-az3 has none of the candidates). AZ names map to different AZs in each
# account, so names[0] alone can land on such an AZ for one customer and not
# another. Read at plan time, so a region with no usable type fails before
# anything is created.
data "aws_ec2_instance_type_offerings" "scan_engine" {
  region        = local.region
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = local.instance_type_candidates
  }

  lifecycle {
    postcondition {
      condition = anytrue([
        for i, t in self.instance_types : contains(data.aws_availability_zones.available.names, self.locations[i])
      ])
      error_message = "No scan engine instance type is offered in ${local.region}: tried ${join(", ", local.instance_type_candidates)}. Deselect this region, or set instance_type to a type the region offers."
    }
  }
}

locals {
  # Every candidate is 8 vCPU / 32 GiB, in the order they are tried. m5 first
  # keeps deployments made before the selection on m5.2xlarge.
  instance_type_candidates = var.instance_type != "" ? [var.instance_type] : ["m5.2xlarge", "m6i.2xlarge", "m7i.2xlarge"]

  offerings = data.aws_ec2_instance_type_offerings.scan_engine
  zone_instance_types = {
    for az in data.aws_availability_zones.available.names :
    az => [for i, t in local.offerings.instance_types : t if local.offerings.locations[i] == az]
  }
  # The first candidate offered in any AZ, then the first AZ (in names order,
  # so names[0] when it offers the type, as before the selection) offering it.
  instance_type = [
    for t in local.instance_type_candidates : t
    if anytrue([for az, types in local.zone_instance_types : contains(types, t)])
  ][0]
  availability_zone = [
    for az in data.aws_availability_zones.available.names : az
    if contains(local.zone_instance_types[az], local.instance_type)
  ][0]
}

resource "aws_vpc" "main" {
  region     = local.region
  cidr_block = var.vpc_cidr
  # DNS must be on or the appliance can't resolve the control_service ALB,
  # API Gateway, or S3 hostnames via the Amazon VPC resolver.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "fortidspm-scan-engine-${local.name_suffix}"
  })
}

resource "aws_internet_gateway" "main" {
  region = local.region
  vpc_id = aws_vpc.main.id
  tags = merge(local.common_tags, {
    Name = "fortidspm-scan-engine-${local.name_suffix}"
  })
}

resource "aws_subnet" "public" {
  region            = local.region
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = local.availability_zone

  tags = merge(local.common_tags, {
    Name = "fortidspm-scan-engine-${local.name_suffix}-public"
  })
}

resource "aws_subnet" "private" {
  region            = local.region
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = local.availability_zone

  tags = merge(local.common_tags, {
    Name = "fortidspm-scan-engine-${local.name_suffix}-private"
  })
}

resource "aws_eip" "nat" {
  region = local.region
  domain = "vpc"
  tags = merge(local.common_tags, {
    Name = "fortidspm-scan-engine-${local.name_suffix}-nat"
  })
}

resource "aws_nat_gateway" "main" {
  region        = local.region
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags = merge(local.common_tags, {
    Name = "fortidspm-scan-engine-${local.name_suffix}"
  })

  # NAT gateway needs the IGW route present before it can provide egress.
  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  region = local.region
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "fortidspm-scan-engine-${local.name_suffix}-public"
  })
}

resource "aws_route_table" "private" {
  region = local.region
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "fortidspm-scan-engine-${local.name_suffix}-private"
  })
}

resource "aws_route_table_association" "public" {
  region         = local.region
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  region         = local.region
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# Free S3 gateway endpoint — keeps bulk customer-S3 reads off the NAT gateway.
resource "aws_vpc_endpoint" "s3" {
  region            = local.region
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = merge(local.common_tags, {
    Name = "fortidspm-scan-engine-${local.name_suffix}-s3"
  })
}

# ---------------------------------------------------------------------------
# IAM role + policy + instance profile
#
# scan_engine reads customer S3 buckets via the EC2 Instance Profile.
# The appliance's boto3 client (dlpcode/storage/connector/aws/connector.py)
# falls back to the default credential chain (IMDSv2) when no static keys
# are supplied, so no scan_engine code change is needed.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "scan_engine_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scan_engine" {
  name               = "fortidspm-scan-engine-${local.name_suffix}"
  assume_role_policy = data.aws_iam_policy_document.scan_engine_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "scan_engine_s3" {
  statement {
    sid    = "S3DiscoveryAndRead"
    effect = "Allow"
    actions = [
      "s3:ListAllMyBuckets",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetBucketAcl",
      "s3:GetBucketPolicyStatus",
      "s3:GetBucketVersioning",
      "s3:GetBucketPublicAccessBlock",
    ]
    # First-version scope: all S3 buckets in the customer's AWS account.
    # Customers can tighten this by replacing "*" with a list of specific bucket ARNs.
    resources = ["*"]
  }

  # Remediation writes/deletes. The connector (aws_file_ops) copies objects to a
  # quarantine location (copy_object -> PutObject on dest, GetObject on source),
  # deletes originals (delete_object), and tags objects (put_object_tagging);
  # aws_recycle moves to recycle. Read-only is not enough for these actions.
  statement {
    sid    = "S3Remediation"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:PutObjectTagging",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudTrailRead"
    effect = "Allow"
    actions = [
      "cloudtrail:ListTrails",
      "cloudtrail:DescribeTrails",
      "cloudtrail:GetEventSelectors",
      "cloudtrail:GetTrailStatus",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "STSCallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid       = "AccountInformation"
    effect    = "Allow"
    actions   = ["account:GetAccountInformation"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "scan_engine_s3" {
  name   = "fortidata-scan-engine-s3-read"
  role   = aws_iam_role.scan_engine.id
  policy = data.aws_iam_policy_document.scan_engine_s3.json
}

resource "aws_iam_instance_profile" "scan_engine" {
  name = "fortidspm-scan-engine-${local.name_suffix}"
  role = aws_iam_role.scan_engine.name
  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Security group: outbound 443 only, no inbound.
#
# scan_engine initiates HTTPS/WSS connections to:
#   - Fortinet control_service ALB (HTTPS API)
#   - Fortinet API Gateway WebSocket endpoint (WSS)
#   - Customer S3 buckets
#   - Fortinet scan-results S3 bucket (via presigned URLs)
# scan_engine never accepts inbound connections.
# ---------------------------------------------------------------------------

resource "aws_security_group" "scan_engine" {
  region      = local.region
  name        = "fortidspm-scan-engine-${local.name_suffix}"
  description = "FortiData scan_engine - outbound HTTPS/WSS to Fortinet control plane and S3"
  vpc_id      = aws_vpc.main.id

  # Optional debug inbound: open TCP 22 and 443 from a single source CIDR.
  # No rule is created unless office_ip is set, so normal operation stays
  # inbound-closed. Only reachable when enable_public_ip is also true.
  dynamic "ingress" {
    for_each = var.office_ip != "" ? toset(["22", "443"]) : toset([])
    content {
      description = "Debug SSH/HTTPS from office_ip"
      from_port   = tonumber(ingress.value)
      to_port     = tonumber(ingress.value)
      protocol    = "tcp"
      cidr_blocks = [var.office_ip]
    }
  }

  # Allow ALL outbound for testing / debugging. The appliance needs at
  # minimum: TCP 443 (HTTPS/WSS), UDP 53 + TCP 53 (DNS — AWS Resolver
  # technically bypasses SG but explicit is clearer), UDP 123 (NTP).
  # Production may tighten to a specific port list once stabilized.
  egress {
    description = "All outbound (HTTPS/WSS, DNS, NTP, debug HTTP, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "fortidspm-scan-engine-${local.name_suffix}"
  })
}

# ---------------------------------------------------------------------------
# EC2 instance running the scan_engine appliance.
#
# user_data is the raw activation_token JWT — not a shell script and not a
# cloud-config yaml. The appliance image does not run cloud-init; instead its
# own boot logic (dlpcode/system/cloud/aws_init.py
# :init_scan_engine_activation_from_user_data) fetches /latest/user-data via
# wget and seeds /var/log/scan_engine/scan_engine_config.json.activation_code.
# ---------------------------------------------------------------------------

resource "aws_instance" "scan_engine" {
  region        = local.region
  ami           = local.ami_id
  instance_type = local.instance_type
  # Default: private subnet, outbound-only via NAT. A public IP only works in an
  # IGW-routed subnet, so enable_public_ip moves the instance to the public
  # subnet as well as assigning the IP — a public IP in the private subnet would
  # be non-functional. Debugging only; see var.enable_public_ip.
  subnet_id            = var.enable_public_ip ? aws_subnet.public.id : aws_subnet.private.id
  iam_instance_profile = aws_iam_instance_profile.scan_engine.name

  vpc_security_group_ids = [aws_security_group.scan_engine.id]

  # scan_engine is outbound-only by default (no public IP; debug via the EC2
  # serial console). enable_public_ip flips this on for temporary debugging.
  associate_public_ip_address = var.enable_public_ip

  # The appliance seeds its config from user-data on FIRST BOOT only
  # (aws_init.py::init_scan_engine_activation_from_user_data). Without
  # user_data_replace_on_change the provider would stop the instance, rewrite
  # the attribute and start it again -- not a first boot -- so a rotated
  # activation_token would land in EC2 and never be read. Replacing the
  # instance is what gets the new token seeded.
  user_data                   = local.activation_token
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    encrypted             = true
    delete_on_termination = true
  }

  # Data/log disk required by the FortiData appliance's fdtinit.sh
  # (check_format_mount_disk mounts a separate block device as /data).
  # The appliance formats this on first boot. Without it, the appliance
  # drops into maintainer shell on startup.
  ebs_block_device {
    device_name           = "/dev/sdb"
    volume_size           = var.log_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional" # Appliance currently uses IMDSv1-style wget; relax until appliance switches to IMDSv2
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  tags = merge(local.common_tags, {
    Name = "fortidspm-scan-engine-${local.name_suffix}"
  })

  # Replacement on a rotated activation_token is driven by
  # user_data_replace_on_change above, not from here.
  lifecycle {
    create_before_destroy = false
    ignore_changes        = []

    # Account guard: when Fortinet baked an account_id, refuse to deploy unless
    # the caller is in that account (a bundle baked for one customer account
    # cannot be applied against another).
    precondition {
      condition     = var.account_id == "" || data.aws_caller_identity.current.account_id == var.account_id
      error_message = "This bundle is baked for AWS account ${var.account_id}, but terraform is running as account ${data.aws_caller_identity.current.account_id}."
    }
    precondition {
      condition     = var.global || var.global_module_reference.lacework_integration_guid != ""
      error_message = "Set global = true on exactly one module instance and pass it as global_module_reference to the others."
    }
    precondition {
      condition     = local.activation_token != "" && local.ami_id != ""
      error_message = "FortiDSPM issued no activation token or AMI for region ${local.region}; add it to the global instance's regions."
    }
  }
}
resource "lacework_fortidspm_deployment_status" "this" {
  count = var.report_deployment_status ? 1 : 0

  intg_guid     = local.integration.lacework_integration_guid
  deployment_id = local.integration.deployment_id
  status        = "succeeded"

  region {
    name                  = local.region
    status                = "succeeded"
    instance_id           = aws_instance.scan_engine.id
    private_ip            = aws_instance.scan_engine.private_ip
    nat_gateway_public_ip = aws_eip.nat.public_ip
    iam_role_arn          = aws_iam_role.scan_engine.arn
  }
}
