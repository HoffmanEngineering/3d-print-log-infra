# Bootstrap

Terraform needs somewhere to keep state and a way for CI to authenticate before it can manage
anything. `bootstrap.sh` creates exactly those things, once, by hand. Everything else is Terraform.

## What it creates

**Azure** (in the subscription `az` currently has selected):

- resource group `rg-printlog-tfstate` (`LOCATION`, default `centralus`)
- storage account `stprintlogtfstate<random>`: StorageV2, LRS, TLS 1.2 minimum, no public blob
  access, **shared-key access disabled**, blob versioning, 30-day soft delete. An existing account
  is reused only if it is the only one in the group (otherwise set `TFSTATE_STORAGE_ACCOUNT`), and
  the TLS, shared-key and public-access settings are re-applied on every run
- container `tfstate`
- the operator (you) gets `Storage Blob Data Owner` on the account, needed to create the container
  without keys
- Entra app `github-3d-print-log-infra-apply`: federated credential for the `production`
  environment, `Storage Blob Data Contributor` on the container
- Entra app `github-3d-print-log-infra-plan`: federated credential for pull requests,
  `Storage Blob Data Reader` on the container (plans run with `-lock=false`)

**AWS** (the account your `aws` credentials point at):

The AWS project's managed policies deny every IAM identity provider, so GitHub's OIDC token can't be
trusted on the AWS side. CI uses two IAM users instead. Each user's access key goes straight from
`aws iam create-access-key` into a GitHub secret: it is never printed, logged or written to state.

- user `/ci/printlog-infra-apply` with `aws-apply-policy.json`, key in the **`production`
  environment** secrets `AWS_APPLY_ACCESS_KEY_ID` / `AWS_APPLY_SECRET_ACCESS_KEY` (only the
  approved apply job on `main` can read them). SES actions
  only on the `mail.3dprintlog.com` identity and `printlog-*` configuration sets (and never a send),
  Route 53 record changes only under `mail.3dprintlog.com`, no hosted-zone deletion, and IAM writes
  only to `/printlog/` users that carry the sender boundary
- user `/ci/printlog-infra-plan` with the read-only `aws-plan-policy.json`, which is explicitly
  denied SES reads that return recipient addresses (suppression list, contacts). Key in the
  repository secrets `AWS_PLAN_ACCESS_KEY_ID` / `AWS_PLAN_SECRET_ACCESS_KEY`, which GitHub never
  gives to fork PRs.
- Both users live under `/ci/`, outside the `/printlog/` path the apply policy may modify, so
  neither can change its own permissions.
- managed policy `/printlog/printlog-ses-sender-boundary` (`aws-sender-boundary.json`): the
  permissions boundary on the API's sender user, allowing nothing but `ses:SendEmail`. It lives
  outside Terraform so the apply user cannot widen it.

## Rotating the CI keys

```bash
ROTATE_AWS_KEYS=1 ./bootstrap/bootstrap.sh
```

This creates a new key for each CI user, stores it in GitHub, then deletes the old one. Rotate if a
key may have leaked, and otherwise about once a year.

## OIDC subjects (Azure)

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
aws login --region us-east-2 --profile printlog   # browser sign-in to the AWS project
export AWS_PROFILE=printlog AWS_REGION=us-east-2
gh auth status
./bootstrap/bootstrap.sh
```

Then set each printed value as a repository variable (`gh variable set NAME --body VALUE`).

## Undo

Delete the two Entra apps, the resource group, the two `/ci/` IAM users (and their keys), the sender
boundary policy, and the four `AWS_*` GitHub secrets. Do this only
after `terraform destroy`, or the state describing live resources is lost.
