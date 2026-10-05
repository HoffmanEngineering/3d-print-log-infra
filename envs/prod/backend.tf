# State lives in Azure Storage, next to the bulk of the estate. The resource group and storage
# account names are supplied with -backend-config at init time (see the workflows and README), so
# this file holds only the parts that never change. Authentication is Entra ID via OIDC: no storage
# account keys exist anywhere in this setup.
terraform {
  backend "azurerm" {
    container_name   = "tfstate"
    key              = "prod.tfstate"
    use_azuread_auth = true
    use_oidc         = true
  }
}
