terraform {
  required_providers {
    aws      = { source = "hashicorp/aws", version = "~> 5.0" }
    lacework = { source = "lacework/lacework", version = ">= 2.6.0" }
  }
}

# LW_ACCOUNT / LW_SUBACCOUNT / LW_API_KEY / LW_API_SECRET from the environment.
provider "lacework" {}

provider "aws" {
  alias  = "us_west_2"
  region = "us-west-2"
}

module "lacework_aws_fortidspm_us_west_2" {
  source = "git::https://github.com/lacework/terraform-aws-fortidspm.git?ref=v0.2.0"

  global                    = true
  lacework_integration_name = "aws-dspm-us-west-2"
  regions                   = ["us-west-2"]

  providers = { aws = aws.us_west_2 }
}

output "lacework_integration_guid" {
  value = module.lacework_aws_fortidspm_us_west_2.lacework_integration_guid
}

output "deployment_id" {
  value = module.lacework_aws_fortidspm_us_west_2.deployment_id
}

output "instance_id" {
  value = module.lacework_aws_fortidspm_us_west_2.instance_id
}

output "nat_gateway_public_ip" {
  description = "Egress IP of the scan engine; allow it on the FortiDSPM side if egress is filtered."
  value       = module.lacework_aws_fortidspm_us_west_2.nat_gateway_public_ip
}
