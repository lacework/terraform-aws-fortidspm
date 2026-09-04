# Provider requirements for the scan_engine module.
#
# Only a lower bound is declared. The root module that calls this one owns the
# exact constraint -- CNAPP's generator emits `aws = "~> 5.0"` -- and a module
# that pinned an upper bound here would make any future root-side move to a
# newer major version unsatisfiable.
#
# No `provider` block: the region comes from the aliased provider the root
# passes in (providers = { aws = aws.<region_alias> }), which is what lets one
# apply cover several regions at once.

terraform {
  required_version = ">= 1.2"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}
