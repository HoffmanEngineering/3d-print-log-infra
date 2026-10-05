provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

# No Azure resources are managed yet; the provider is declared so the backend and future imports
# share one authenticated configuration.
provider "azurerm" {
  features {}
  use_oidc            = true
  storage_use_azuread = true
}
