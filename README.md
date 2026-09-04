# terraform-aws-fortidspm

Terraform module that deploys one FortiDSPM **scan engine** into a single AWS
region: an isolated VPC, its networking, an IAM role, and the EC2 appliance.

This module belongs to the **FortiDSPM** architecture, in which the scan engine
pushes results to FortiCNAPP through presigned URLs. It is not related to
[`terraform-aws-dspm`](https://github.com/lacework/terraform-aws-dspm), which
implements the earlier design where results landed in a bucket in the
customer's own account and FortiCNAPP read them back over a cross-account role.

## What it creates

| Resource | Purpose |
|---|---|
| `aws_vpc`, public/private `aws_subnet`, `aws_internet_gateway` | Isolated network |
| `aws_nat_gateway` + `aws_eip` | Outbound-only egress for the appliance |
| `aws_vpc_endpoint` (S3, gateway) | S3 traffic stays off the NAT gateway |
| `aws_iam_role` + instance profile + inline policy | Read access the scanner needs |
| `aws_security_group` | Egress only; nothing is allowed in |
| `aws_instance` | The scan engine appliance itself |

The instance sits in the **private** subnet with no public IP by default.

## Usage

The module takes the region from the provider passed to it and **declares no
provider of its own**. Instantiate it once per region with an aliased provider,
and one `terraform apply` covers every region in a single state.

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  alias  = "us_west_2"
  region = "us-west-2"
}

module "scan_engine_us_west_2" {
  source = "github.com/lacework/terraform-aws-fortidspm?ref=v0.1.0"

  providers = { aws = aws.us_west_2 }

  activation_token = var.activation_token_us_west_2  # from FortiDSPM, per region
  ami_id           = var.ami_id_us_west_2            # from FortiDSPM, per region
  aws_region       = "us-west-2"

  deployment_id   = "d-1a2b3c4d"
  deployment_name = "aws-dspm-123456789012"
}
```

`activation_token` and `ami_id` are **per region** and are issued by FortiDSPM
when the deployment is created. Everything else has a working default.

## Inputs

Required:

| Name | Description |
|---|---|
| `activation_token` | One-time JWT signed by FortiDSPM's control service, **specific to this region**. Delivered to the appliance through EC2 user-data and consumed on first boot. |
| `ami_id` | BYOL AMI for this region. AMI ids are region-scoped, so each region gets its own. |
| `aws_region` | The region this instance deploys into. Used for the S3 endpoint service name and in messages. |
| `deployment_id` | Identifies the deployment. Takes part in resource naming, which keeps two deployments in one account apart. |
| `deployment_name` | Human-readable name, applied as a tag. |

Optional, with defaults: `account_id`, `env_id`, `enable_cloudtrail`,
`vpc_cidr`, `public_subnet_cidr`, `private_subnet_cidr`, `enable_public_ip`,
`office_ip`, `instance_type`, `root_volume_size`, `root_volume_type`,
`log_volume_size`, `extra_tags`.

Setting `account_id` turns on a precondition that refuses to apply unless the
caller is in that account, so a bundle minted for one customer cannot be
deployed into another.

See `variables.tf` for the full descriptions and defaults.

## Outputs

`instance_id`, `private_ip`, `public_ip`, `vpc_id`, `nat_gateway_public_ip`,
`iam_role_arn`, `iam_role_name`, `security_group_id`.

## Notes

**Naming is deterministic — there is no random suffix.** Names combine the
region (which keeps account-global IAM names from colliding across the regions
of one deployment) with `deployment_id` (which keeps separate deployments
apart). Re-deploying the same `deployment_id` into the same account therefore
fails on the duplicate IAM role, which is a deliberate guard against deploying
the same storage profile twice.

**`activation_token` is single-use.** The appliance exchanges it for long-lived
credentials the first time it boots. If the instance is ever rebuilt, ask
FortiDSPM for a fresh token — reusing the spent one leaves the appliance
unregistered.

## License

MIT. See [LICENSE](./LICENSE).
