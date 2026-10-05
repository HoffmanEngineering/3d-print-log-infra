# Bootstrap

Terraform needs somewhere to keep state and a way for CI to authenticate before it can manage
anything. `bootstrap.sh` creates exactly those things, once, by hand. Everything else is Terraform.

## What it creates

**Azure** (in the subscription `az` currently has selected):

- resource group `rg-printlog-tfstate` (`LOCATION`, default `centralus`)
- storage account `stprintlogtfstate<random>`: StorageV2, LRS, TLS 1.2 minimum, no public blob
  access, **shared-key access disabled**, blob versioning, 30-day soft delete
- container `tfstate`
- the operator (you) gets `Storage Blob Data Owner` on the account, needed to create the container
  without keys
- Entra app `github-3d-print-log-infra-apply`: federated credential for the `production`
  environment, `Storage Blob Data Contributor` on the container
- Entra app `github-3d-print-log-infra-plan`: federated credential for pull requests,
  `Storage Blob Data Reader` on the container (plans run with `-lock=false`)

**AWS** (the account your `aws` credentials point at):

- the IAM OIDC provider for `token.actions.githubusercontent.com`
- role `printlog-infra-apply` (production environment) with `aws-apply-policy.json`
- role `printlog-infra-plan` (pull requests) with the read-only `aws-plan-policy.json`

## OIDC subjects

This repository was created after 2026-07-15, so GitHub issues **immutable** subject claims that
include the owner and repository ids:

```
repo:HoffmanEngineering@<owner_id>/3d-print-log-infra@<repo_id>:environment:production
repo:HoffmanEngineering@<owner_id>/3d-print-log-infra@<repo_id>:pull_request
```

The script derives the ids with `gh api`. Before relying on them, run the **OIDC claims** workflow
(Actions → "OIDC claims" → Run workflow) and check that the printed `sub` matches the apply subject
the script logged.

## Running it

```bash
az login && az account set --subscription "<subscription>"
aws configure   # or export credentials for the target account
gh auth status
./bootstrap/bootstrap.sh
```

Then set each printed value as a repository variable (`gh variable set NAME --body VALUE`).

## Undo

Delete the two Entra apps, the resource group, the two IAM roles and the OIDC provider. Do this only
after `terraform destroy`, or the state describing live resources is lost.
