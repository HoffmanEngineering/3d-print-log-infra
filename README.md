# 3D Print Log Infrastructure

Terraform for the infrastructure behind [3D Print Log](https://www.3dprintlog.com): the
[UI](https://github.com/HoffmanEngineering/3d-print-log-ui) and
[API](https://github.com/HoffmanEngineering/3d-print-log-api).

The first resident is the AWS SES email stack. The existing Azure resources (App Service, SQL,
Storage, Static Web Apps) will be imported here over time, one resource group at a time, with
`import` blocks so nothing is recreated.

## The AWS project

AWS hosts this stack in a project from AWS's newer sign-up experience. A project is a single account
that AWS manages inside its own organization. Two things follow from that:

- **Region is fixed at `us-east-2` (Ohio).** AWS's managed service control policies deny regional
  resources anywhere else, so `aws_region` is pinned by validation.
- **No IAM identity providers.** GitHub's OIDC token can't be trusted, so CI uses IAM user keys
  stored as GitHub secrets (see bootstrap).
- **Human access is `aws login`, not IAM users or Identity Center.** Use the `printlog` profile
  (`aws login --region us-east-2 --profile printlog`). The IAM users (the API's SES sender and
  the two CI users) are programmatic-only.

A spend limit can be set per project in AWS Settings. If it is ever exceeded, AWS pauses the project
and SES stops sending until it is raised.

## Layout

```
bootstrap/          one-time script: Terraform state storage + CI credentials (run by hand)
modules/
  email-ses/        an SES sending domain: zone, DKIM, MAIL FROM, DMARC, events, sender user
envs/
  prod/             root module: backend, providers, module wiring, account-level settings
.github/workflows/  terraform-plan (PRs), terraform-apply (main), oidc-claims (manual check)
```

## How changes ship

- **Pull request:** `fmt`, `validate` and `tflint` run for every PR. For branches in this repo, a
  read-only principal also runs `terraform plan` and posts it as a PR comment. Fork PRs never get
  cloud credentials.
- **Merge to `main`:** `terraform apply` runs behind the `production` environment's required
  reviewer. Applies never run concurrently.
- State is in Azure Storage (`tfstate` container), authenticated with Entra ID. Azure trusts
  GitHub's OIDC tokens, so there are no Azure keys anywhere. AWS can't: the project denies IAM
  identity providers. CI therefore uses two IAM users whose keys bootstrap stores as GitHub
  secrets: a read-only plan key (repository secret) and the apply key (`production` environment
  secret, readable only by the approved apply job on `main`).

**This repository is public.** Never commit `*.tfvars` with real values, plan files, or anything
secret. Nothing in Terraform state is secret by design: the one credential this stack needs (the
API's SES access key) is created by hand.

## First-time setup and manual steps

These cannot be automated, or are deliberately manual. Do them in order.

1. [ ] **Bootstrap.** Run [`bootstrap/bootstrap.sh`](bootstrap/README.md) and store the printed values
       as repository variables (the AWS keys are stored as secrets automatically). Run the **OIDC
       claims** workflow and confirm the printed `sub` matches. Re-run it whenever a file under
       `bootstrap/` changes: the CI users' policies and the sender's permissions boundary are applied
       by the script, not by Terraform.
2. [ ] **Terraform inputs:** the `ALERTS_EMAIL` *secret* (inbox for SES alarms; a secret because
       Actions logs and plan comments on this public repo are public) and, later, the
       `SES_EVENT_WEBHOOK_URL` variable. The workflows map them to `TF_VAR_*`.
3. [ ] **First apply** (merge to `main`, approve the `production` deployment).
4. [ ] **Delegate `mail.3dprintlog.com`.** At Namecheap → Advanced DNS, add four `NS` records for host
       `mail`, one per value of the `mail_name_servers` output.
5. [ ] **Apex DMARC.** Create a `dmarc@3dprintlog.com` alias in Zoho, then add at Namecheap:
       `TXT` host `_dmarc` value `v=DMARC1; p=none; rua=mailto:dmarc@3dprintlog.com; fo=1`.
6. [ ] **Check DKIM** once DNS propagates (see [`modules/email-ses`](modules/email-ses/README.md)):
       status `SUCCESS`, signing zone `dkim.amazonses.com`.
7. [ ] **Request SES production access:**

       ```bash
       AWS_PROFILE=printlog AWS_REGION=us-east-2 aws sesv2 put-account-details --production-access-enabled --mail-type MARKETING \
         --website-url https://www.3dprintlog.com --contact-language EN \
         --use-case-description "3D Print Log (a free hobbyist 3D-printing logbook) sends account-activity email to its own registered users: an onboarding series for new signups, a monthly recap of each user's own print statistics, and an alert when a user's connected printer stops reporting. Recipients are verified account addresses only, never purchased lists. Every message carries RFC 8058 one-click unsubscribe plus per-category preferences, users are shown an in-app notice before any email is sent, and permanent bounces and complaints are suppressed automatically from SES event notifications. Expected volume is a few hundred messages per day, ramping to about 5,000 on the first of each month."
       ```

       `MARKETING` is declared because these are scheduled engagement emails, not one-to-one
       transactional mail triggered by a user action.
8. [ ] **Confirm the alerts subscription** from the `alerts_email` inbox. It receives the reputation
       alarms and the dead-letter alarm for SES events.
9. [ ] **API credentials.** Create the key by hand and put it in App Service settings, so the secret
       never enters Terraform state:

       ```bash
       aws iam create-access-key --user-name printlog-api-ses-sender
       ```

       App Service settings: `Email__Ses__AccessKeyId`, `Email__Ses__SecretAccessKey` (ideally as a
       Key Vault reference, so the secret is not readable by anyone with App Service config access),
       `Email__Ses__Region=us-east-2`, `Email__Ses__ConfigurationSet` (output
       `ses_configuration_set_name`), `Email__Ses__EventsTopicArn` (output `ses_events_topic_arn`).
10. [ ] **Webhook.** After the API's `/api/email-events/ses` endpoint is deployed, set the
        `SES_EVENT_WEBHOOK_URL` repository variable to `https://<api-host>/api/email-events/ses`, apply, and check
        the subscription shows `Confirmed` (`aws sns list-subscriptions-by-topic`).
11. [ ] **App Service "Always On"** must be enabled on the API: its email workers run in-process.

## Rotating the SES access key

1. `aws iam create-access-key --user-name printlog-api-ses-sender` (a user may hold two keys).
2. Update the two App Service settings; restart the API.
3. Confirm sends succeed (API telemetry `Email_Sent`), then
   `aws iam delete-access-key --user-name printlog-api-ses-sender --access-key-id <old>`.

## Local use

```bash
cd envs/prod
terraform init -backend-config=resource_group_name=rg-printlog-tfstate \
               -backend-config=storage_account_name=<account>
terraform plan -lock=false -var alerts_email=you@example.com
```

Local plans need an Entra identity with blob read access to the state container.
