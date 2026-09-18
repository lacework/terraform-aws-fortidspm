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

One module instance per region, each with its own aliased `aws` provider (the
module declares no provider of its own). Exactly one instance sets
`global = true`: it creates the `lacework_integration_aws_fortidspm` resource,
which registers the account with FortiCNAPP and receives from FortiDSPM one
single-use activation token and one AMI per region. The other instances take
that module as `global_module_reference` and read their own region's token and
AMI from it. One `terraform apply` covers every region in a single state.

```hcl
terraform {
  required_providers {
    aws      = { source = "hashicorp/aws", version = "~> 5.0" }
    lacework = { source = "lacework/lacework", version = ">= 2.6.0" }
  }
}

provider "lacework" {} # LW_ACCOUNT / LW_API_KEY / LW_API_SECRET from the environment

provider "aws" {
  alias  = "us_west_2"
  region = "us-west-2"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

module "lacework_aws_fortidspm_us_west_2" {
  source = "git::https://github.com/lacework/terraform-aws-fortidspm.git?ref=v0.2.0"

  global                    = true
  lacework_integration_name = "aws-dspm-123456789012"
  regions                   = ["us-west-2", "us-east-1"]

  providers = { aws = aws.us_west_2 }
}

module "lacework_aws_fortidspm_us_east_1" {
  source = "git::https://github.com/lacework/terraform-aws-fortidspm.git?ref=v0.2.0"

  global_module_reference = module.lacework_aws_fortidspm_us_west_2

  providers = { aws = aws.us_east_1 }
}
```

The activation token is single-use. Rebuilding an instance needs a new token,
which means a new integration: taint the module's
`lacework_integration_aws_fortidspm` resource and apply again.

## Examples

Complete root modules, validated against this tag:

- [`examples/single-region`](examples/single-region) — one region with the integration
- [`examples/multi-region`](examples/multi-region) — the global instance plus a second region, sharing one integration

Run one with the FortiCNAPP API key in the environment (`LW_ACCOUNT` may be the
full account domain, `LW_SUBACCOUNT` names the sub-account for organisation
accounts) and the cloud credentials the provider blocks expect, then
`terraform init && terraform apply`. `terraform destroy` removes the scan
engines, deletes the FortiCNAPP integration and notifies FortiDSPM.

## Inputs

| Name | Description |
|---|---|
| `global` | Create the FortiCNAPP DSPM integration in this instance. Exactly one instance per deployment. Default `false`. |
| `global_module_reference` | The instance with `global = true`, passed whole (`module.<name>`). Required when `global = false`. |
| `regions` | Every region a scan engine is deployed in, including this one. Global instance only. |
| `lacework_integration_name` | Name of the FortiCNAPP DSPM integration. Global instance only. Default `aws-fortidspm`. |
| `account_id` | AWS account the scan engines belong to. Empty = the caller identity's account. Terraform refuses to deploy from a different account. |

Optional, with defaults: `report_deployment_status` (tell FortiDSPM the region's
scan engine is up, default `true`), `enable_cloudtrail`, `vpc_cidr`, `public_subnet_cidr`,
`private_subnet_cidr`, `enable_public_ip`, `office_ip`, `instance_type`,
`root_volume_size`, `root_volume_type`, `log_volume_size`, `extra_tags`.
The region comes from the provider passed in.

## Outputs

Per instance: `instance_id`, `private_ip`, `public_ip`, `vpc_id`,
`nat_gateway_public_ip`, `iam_role_arn`, `iam_role_name`, `security_group_id`.

Shared, read by the non-global instances through `global_module_reference`:
`lacework_integration_guid`, `deployment_id`, `deployment_name`, `env_id`,
`activation_tokens` (sensitive), `image_ids`.

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
