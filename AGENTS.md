# AGENTS.md

Guidance for coding agents in this repo. `CLAUDE.md` points here, so this is the one file to edit.
README.md explains the AWS project, the layout, how changes ship and every manual step; read it
before changing anything.

This is the Terraform for 3D Print Log's production infrastructure: today the AWS SES email stack,
later the Azure resources behind the UI and API.

## This repo deploys production

- **A merge to `main` runs `terraform apply`** against production, behind the `production`
  environment's required reviewer (Chris). Merging is deploying: merge only when Chris asks, after he
  has read the plan.
- Never run `terraform apply`, `import` or `state` commands locally. Local work is `fmt`, `validate`,
  `tflint` and, with Chris's Entra login, `terraform plan -lock=false` (README "Local use").
- A PR from a branch in this repo gets a `terraform plan` comment from CI. Read it and report every
  resource it would destroy or replace before calling the PR ready.

## Rules that are easy to break

- **The repo is public**, and so are the Actions logs and plan comments. Never commit `*.tfvars` with
  real values, plan files or secrets. Values that are private (such as the alerts email) are GitHub
  secrets mapped to `TF_VAR_*`.
- AWS region is fixed at `us-east-2`: the AWS project's policies deny everything else.
- The AWS project can't trust GitHub's OIDC, so CI uses IAM user keys. Their policies, and the SES
  sender's permissions boundary, live in `bootstrap/*.json` and are applied by `bootstrap.sh`, not
  by Terraform. A change there means Chris re-runs the script.
- The hosted zone has `prevent_destroy`; keep it. Existing Azure resources come in with `import`
  blocks, one resource group at a time, never by recreating them.
- DNS at Namecheap (the `mail` NS delegation, apex DMARC, the MCP Registry TXT record) is manual and
  listed in the README; Terraform doesn't own it.
- Terraform version: `.terraform-version` (1.16.4), the same one the workflows pin.

## Checks

```sh
terraform fmt -check -recursive
cd envs/prod && terraform init -backend=false && terraform validate
cd ../..
tflint --init --config "$PWD/.tflint.hcl"
tflint --chdir=envs/prod --config "$PWD/.tflint.hcl" --call-module-type=local
```

These are the PR workflow's static checks, in the same order.

## Commits and PRs

Never add a `Claude-Session:` trailer or a `claude.ai/code/session_…` link to a commit message, PR
title or PR body. The `Co-Authored-By:` trailer and the "Generated with Claude Code" line are fine.
