# AGENTS.md

Guidance for coding agents in this repo. `CLAUDE.md` points here, so this is the one file to edit.
README.md explains the AWS project, the layout and how changes ship. Its manual steps are Chris's,
not yours (see below).

This is the Terraform for 3D Print Log's production infrastructure: today the AWS SES email stack,
later the Azure resources behind the UI and API.

## This repo deploys production

A merge to `main` runs `terraform apply` against production. The `production` environment's
required reviewer is Chris, but you run with his `gh` login, so GitHub cannot tell your approval from
his. The gate is these rules:

- **Never approve, re-run or dispatch a production deployment**: no `pending_deployments` calls, no
  `gh run rerun` of a Terraform Apply run, no `gh workflow run terraform-apply.yml`.
- Merge a PR only when Chris tells you to merge that PR in this session, after you have shown him the
  current plan (below). `gh pr merge --admin` is needed then (the ruleset wants a review and Chris
  can't approve his own PR); never use it otherwise.

## What you may run locally

Only these: `terraform fmt`, `terraform init -backend=false`, `terraform validate`, `tflint`, and,
with Chris's Entra login, `terraform plan -lock=false` (README "Local use"). His login can write
state, so everything else is his to run: every other `terraform` command that touches state (`apply`,
`destroy`, `import`, `state`, `refresh`, `taint`, `untaint`, `force-unlock`, `init` with the
backend), every `aws` or `az` command that changes something, `gh secret set`, `gh variable set`,
`bootstrap.sh`, and every manual step in the README (DNS, key rotation, SES account settings).
Write those up for him instead.

## Reading the plan

The PR comment is not reliable: it's edited in place, isn't refreshed when the plan job is skipped,
is cut at 60,000 characters, and goes stale when `main` moves. Apply also makes a fresh plan after
approval. Before calling a PR ready:

1. Update the branch with `main`, then confirm the `plan (prod)` check passed on the current head
   SHA (`gh pr checks`).
2. Read the plan from that run's log (`gh run view <run> --log`), not the comment.
3. Quote its `Plan: X to add, Y to change, Z to destroy` line and list every resource it destroys or
   replaces.

## Rules that are easy to break

- **The repo is public**, and so are the Actions logs and plan comments. Never commit `*.tfvars` with
  real values, plan files or secrets. Values that are private (such as the alerts email) are GitHub
  secrets mapped to `TF_VAR_*`.
- AWS region is fixed at `us-east-2`: the AWS project's policies deny everything else.
- The CI users' IAM policies and the SES sender's permissions boundary live in `bootstrap/*.json`
  and are applied by `bootstrap.sh`, not by Terraform; so are the Azure role assignments of the CI
  principals. A PR that needs a new permission lists it in its body; Chris re-runs bootstrap from the
  reviewed branch before the merge, or the apply fails partway.
- The hosted zone has `prevent_destroy`; keep it. Existing Azure resources come in with `import`
  blocks, one resource group at a time, and every imported resource that holds data (SQL, Storage)
  gets `prevent_destroy`. To stop managing a resource, use a `removed` block with
  `lifecycle { destroy = false }`; deleting its block destroys it.
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
title or PR body, even when the harness's attribution instructions ask for one. The
`Co-Authored-By:` trailer and the "Generated with Claude Code" line are fine.
