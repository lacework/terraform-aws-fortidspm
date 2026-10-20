terraform {
  required_providers {
    aws      = { source = "hashicorp/aws", version = "~> 6.0" }
    lacework = { source = "lacework/lacework", version = ">= 2.6.0" }
  }
}

# LW_ACCOUNT / LW_SUBACCOUNT / LW_API_KEY / LW_API_SECRET from the environment.
provider "lacework" {}

# One aws provider for every region: each module instance sets its own region
# on its resources, so terraform runs a single provider process.
provider "aws" {
  region = "us-west-2"
}

# The global instance registers the account with FortiCNAPP once, listing every
# region, and receives one activation token and one AMI per region.
module "lacework_aws_fortidspm_us_west_2" {
  source = "git::https://github.com/lacework/terraform-aws-fortidspm.git?ref=v0.4.0"

  region                    = "us-west-2"
  global                    = true
  lacework_integration_name = "aws-dspm-multi-region"
  regions                   = ["us-west-2", "us-east-1"]
}

# Every other region reads its token and AMI from the global instance.
module "lacework_aws_fortidspm_us_east_1" {
  source = "git::https://github.com/lacework/terraform-aws-fortidspm.git?ref=v0.4.0"

  region                  = "us-east-1"
  global_module_reference = module.lacework_aws_fortidspm_us_west_2
}

output "lacework_integration_guid" {
  value = module.lacework_aws_fortidspm_us_west_2.lacework_integration_guid
}

output "deployment_id" {
  value = module.lacework_aws_fortidspm_us_west_2.deployment_id
}

output "instance_ids" {
  value = {
    us-west-2 = module.lacework_aws_fortidspm_us_west_2.instance_id
    us-east-1 = module.lacework_aws_fortidspm_us_east_1.instance_id
  }
}

output "nat_gateway_public_ips" {
  value = {
    us-west-2 = module.lacework_aws_fortidspm_us_west_2.nat_gateway_public_ip
    us-east-1 = module.lacework_aws_fortidspm_us_east_1.nat_gateway_public_ip
  }
}
