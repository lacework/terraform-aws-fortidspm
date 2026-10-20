# Provider requirements for the scan_engine module.
#
# Only a lower bound is declared. The root module that calls this one owns the
# exact constraint -- CNAPP's generator emits `aws = "~> 5.0"` -- and a module
# that pinned an upper bound here would make any future root-side move to a
# newer major version unsatisfiable.
#
# No `provider` block: the region is var.region, set per resource (which needs
# aws >= 6.0), so one apply covers several regions through a single provider.
# An empty var.region falls back to the region of the provider the root passed in.

terraform {
  required_version = ">= 1.2"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0" # resource-level `region` argument
    }
    lacework = {
      source  = "lacework/lacework"
      version = ">= 2.6.0" # lacework_integration_*_fortidspm and lacework_fortidspm_deployment_status first shipped in 2.6.0
    }
  }
}
