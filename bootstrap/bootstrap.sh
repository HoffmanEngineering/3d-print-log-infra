#!/usr/bin/env bash
# One-time bootstrap for 3d-print-log-infra. Creates the two things Terraform cannot create for
# itself: somewhere to keep its state, and the OIDC trust that lets GitHub Actions run it without
# stored cloud keys. Safe to re-run: every create is preceded by an existence check.
#
# Requires: az (logged in, correct subscription selected), aws (credentials for the target
# account), gh (authenticated). See bootstrap/README.md.
set -euo pipefail

OWNER="HoffmanEngineering"
REPO="3d-print-log-infra"
LOCATION="${LOCATION:-centralus}"
TFSTATE_RG="${TFSTATE_RG:-rg-printlog-tfstate}"
TFSTATE_CONTAINER="tfstate"
APPLY_APP_NAME="github-${REPO}-apply"
PLAN_APP_NAME="github-${REPO}-plan"
AWS_APPLY_ROLE="printlog-infra-apply"
AWS_PLAN_ROLE="printlog-infra-plan"
GITHUB_OIDC_HOST="token.actions.githubusercontent.com"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Progress goes to stderr so it never pollutes values captured with $(...).
log() { printf '==> %s\n' "$*" >&2; }

for tool in az aws gh; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }
done

# --- GitHub OIDC subjects ---------------------------------------------------------------------
# Repositories created after 2026-07-15 receive immutable subject claims that embed the owner and
# repository ids. Derive them rather than hard-coding, and confirm with .github/workflows/oidc-claims.yml.
OWNER_ID="$(gh api "repos/${OWNER}/${REPO}" -q .owner.id)"
REPO_ID="$(gh api "repos/${OWNER}/${REPO}" -q .id)"
SUBJECT_PREFIX="repo:${OWNER}@${OWNER_ID}/${REPO}@${REPO_ID}"
APPLY_SUBJECT="${SUBJECT_PREFIX}:environment:production"
PLAN_SUBJECT="${SUBJECT_PREFIX}:pull_request"
log "apply subject: ${APPLY_SUBJECT}"
log "plan subject:  ${PLAN_SUBJECT}"

# --- Azure: state storage ---------------------------------------------------------------------
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

if [ "$(az group exists --name "$TFSTATE_RG")" != "true" ]; then
  log "creating resource group ${TFSTATE_RG}"
  az group create --name "$TFSTATE_RG" --location "$LOCATION" --tags project=3d-print-log managed-by=bootstrap >/dev/null
fi

# Never guess between several accounts: an existing one is picked up only if it is the only one.
if [ -z "${TFSTATE_STORAGE_ACCOUNT:-}" ]; then
  mapfile -t EXISTING_ACCOUNTS < <(az storage account list --resource-group "$TFSTATE_RG" --query '[].name' -o tsv)
  if [ "${#EXISTING_ACCOUNTS[@]}" -gt 1 ]; then
    echo "${TFSTATE_RG} holds ${#EXISTING_ACCOUNTS[@]} storage accounts; set TFSTATE_STORAGE_ACCOUNT to choose one." >&2
    exit 1
  fi
  TFSTATE_STORAGE_ACCOUNT="${EXISTING_ACCOUNTS[0]:-}"
fi
if [ -z "$TFSTATE_STORAGE_ACCOUNT" ]; then
  TFSTATE_STORAGE_ACCOUNT="stprintlogtfstate$(od -An -N2 -tx1 /dev/urandom | tr -d ' 
')"
  log "creating storage account ${TFSTATE_STORAGE_ACCOUNT}"
  az storage account create     --name "$TFSTATE_STORAGE_ACCOUNT"     --resource-group "$TFSTATE_RG"     --location "$LOCATION"     --sku Standard_LRS     --kind StorageV2     --min-tls-version TLS1_2     --allow-blob-public-access false     --allow-shared-key-access false     --tags project=3d-print-log managed-by=bootstrap >/dev/null
fi

# Re-applied on every run, so an account that pre-dates this script or has drifted is brought back.
log "enforcing TLS 1.2, no shared keys and no public blobs on ${TFSTATE_STORAGE_ACCOUNT}"
az storage account update   --name "$TFSTATE_STORAGE_ACCOUNT"   --resource-group "$TFSTATE_RG"   --min-tls-version TLS1_2   --allow-blob-public-access false   --allow-shared-key-access false >/dev/null
STORAGE_ID="$(az storage account show --name "$TFSTATE_STORAGE_ACCOUNT" --resource-group "$TFSTATE_RG" --query id -o tsv)"

log "enabling blob versioning and soft delete"
az storage account blob-service-properties update \
  --account-name "$TFSTATE_STORAGE_ACCOUNT" \
  --resource-group "$TFSTATE_RG" \
  --enable-versioning true \
  --enable-delete-retention true \
  --delete-retention-days 30 >/dev/null

# Shared-key access is disabled, so the operator needs a data-plane role to create the container.
OPERATOR_ID="$(az ad signed-in-user show --query id -o tsv)"
if [ -z "$(az role assignment list --assignee "$OPERATOR_ID" --scope "$STORAGE_ID" --role "Storage Blob Data Owner" --query '[0].id' -o tsv)" ]; then
  log "granting the operator Storage Blob Data Owner on the state account"
  az role assignment create --assignee-object-id "$OPERATOR_ID" --assignee-principal-type User \
    --role "Storage Blob Data Owner" --scope "$STORAGE_ID" >/dev/null
  log "waiting 60s for the role assignment to propagate"
  sleep 60
fi

if [ "$(az storage container exists --name "$TFSTATE_CONTAINER" --account-name "$TFSTATE_STORAGE_ACCOUNT" --auth-mode login --query exists -o tsv)" != "true" ]; then
  log "creating container ${TFSTATE_CONTAINER}"
  az storage container create --name "$TFSTATE_CONTAINER" --account-name "$TFSTATE_STORAGE_ACCOUNT" --auth-mode login >/dev/null
fi
if [ "$(az storage container show --name "$TFSTATE_CONTAINER" --account-name "$TFSTATE_STORAGE_ACCOUNT" --auth-mode login --query properties.publicAccess -o tsv)" != "" ]; then
  echo "container ${TFSTATE_CONTAINER} allows public access; fix it before continuing." >&2
  exit 1
fi
CONTAINER_SCOPE="${STORAGE_ID}/blobServices/default/containers/${TFSTATE_CONTAINER}"

# --- Azure: OIDC principals -------------------------------------------------------------------
ensure_azure_principal() {
  local app_name=$1 subject=$2 credential_name=$3 role=$4
  local app_id sp_id

  app_id="$(az ad app list --display-name "$app_name" --query '[0].appId' -o tsv)"
  if [ -z "$app_id" ]; then
    log "creating Entra app ${app_name}"
    app_id="$(az ad app create --display-name "$app_name" --query appId -o tsv)"
  fi

  sp_id="$(az ad sp list --filter "appId eq '${app_id}'" --query '[0].id' -o tsv)"
  if [ -z "$sp_id" ]; then
    sp_id="$(az ad sp create --id "$app_id" --query id -o tsv)"
  fi

  if [ -z "$(az ad app federated-credential list --id "$app_id" --query "[?subject=='${subject}'].id" -o tsv)" ]; then
    log "adding federated credential ${credential_name} to ${app_name}"
    az ad app federated-credential create --id "$app_id" --parameters "{
      \"name\": \"${credential_name}\",
      \"issuer\": \"https://${GITHUB_OIDC_HOST}\",
      \"subject\": \"${subject}\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" >/dev/null
  fi

  if [ -z "$(az role assignment list --assignee "$sp_id" --scope "$CONTAINER_SCOPE" --role "$role" --query '[0].id' -o tsv)" ]; then
    log "granting ${role} on the state container to ${app_name}"
    az role assignment create --assignee-object-id "$sp_id" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$CONTAINER_SCOPE" >/dev/null
  fi

  printf '%s' "$app_id"
}

AZURE_APPLY_CLIENT_ID="$(ensure_azure_principal "$APPLY_APP_NAME" "$APPLY_SUBJECT" production "Storage Blob Data Contributor")"
# A data-plane reader: plain "Reader" is management-plane only and cannot read state. Plans run
# with -lock=false because a reader cannot take a blob lease.
AZURE_PLAN_CLIENT_ID="$(ensure_azure_principal "$PLAN_APP_NAME" "$PLAN_SUBJECT" pull-request "Storage Blob Data Reader")"

# --- AWS: OIDC provider and roles -------------------------------------------------------------
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
AWS_REGION="${AWS_REGION:-us-east-2}"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${GITHUB_OIDC_HOST}"

if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" >/dev/null 2>&1; then
  log "creating the GitHub OIDC provider in AWS"
  aws iam create-open-id-connect-provider \
    --url "https://${GITHUB_OIDC_HOST}" \
    --client-id-list sts.amazonaws.com >/dev/null
fi

ensure_aws_role() {
  local role_name=$1 subject=$2 policy_file=$3
  local trust
  trust="$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${GITHUB_OIDC_HOST}:aud": "sts.amazonaws.com",
        "${GITHUB_OIDC_HOST}:sub": "${subject}"
      }
    }
  }]
}
JSON
)"

  if aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$role_name" --policy-document "$trust" >/dev/null
  else
    log "creating IAM role ${role_name}"
    aws iam create-role --role-name "$role_name" --assume-role-policy-document "$trust" \
      --tags Key=project,Value=3d-print-log Key=managed-by,Value=bootstrap >/dev/null
  fi

  aws iam put-role-policy --role-name "$role_name" --policy-name "${role_name}-permissions" \
    --policy-document "file://${policy_file}" >/dev/null

  aws iam get-role --role-name "$role_name" --query Role.Arn --output text
}

# The sender user's permissions boundary lives outside Terraform on purpose: the apply role may only
# create or change /printlog/ users that carry it, and cannot edit it.
SENDER_BOUNDARY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/printlog/printlog-ses-sender-boundary"
if aws iam get-policy --policy-arn "$SENDER_BOUNDARY_ARN" >/dev/null 2>&1; then
  for version in $(aws iam list-policy-versions --policy-arn "$SENDER_BOUNDARY_ARN"     --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$SENDER_BOUNDARY_ARN" --version-id "$version"
  done
  aws iam create-policy-version --policy-arn "$SENDER_BOUNDARY_ARN" --set-as-default     --policy-document "file://${SCRIPT_DIR}/aws-sender-boundary.json" >/dev/null
else
  log "creating the SES sender permissions boundary"
  aws iam create-policy --policy-name printlog-ses-sender-boundary --path /printlog/     --policy-document "file://${SCRIPT_DIR}/aws-sender-boundary.json"     --tags Key=project,Value=3d-print-log Key=managed-by,Value=bootstrap >/dev/null
fi

AWS_APPLY_ROLE_ARN="$(ensure_aws_role "$AWS_APPLY_ROLE" "$APPLY_SUBJECT" "${SCRIPT_DIR}/aws-apply-policy.json")"
AWS_PLAN_ROLE_ARN="$(ensure_aws_role "$AWS_PLAN_ROLE" "$PLAN_SUBJECT" "${SCRIPT_DIR}/aws-plan-policy.json")"

# --- Output -------------------------------------------------------------------------------------
cat <<OUT

Bootstrap complete. Store these as GitHub Actions *variables* on ${OWNER}/${REPO}
(none of them are secrets):

  AZURE_APPLY_CLIENT_ID=${AZURE_APPLY_CLIENT_ID}
  AZURE_PLAN_CLIENT_ID=${AZURE_PLAN_CLIENT_ID}
  AZURE_TENANT_ID=${TENANT_ID}
  AZURE_SUBSCRIPTION_ID=${SUBSCRIPTION_ID}
  TFSTATE_RESOURCE_GROUP=${TFSTATE_RG}
  TFSTATE_STORAGE_ACCOUNT=${TFSTATE_STORAGE_ACCOUNT}
  AWS_APPLY_ROLE_ARN=${AWS_APPLY_ROLE_ARN}
  AWS_PLAN_ROLE_ARN=${AWS_PLAN_ROLE_ARN}
  AWS_REGION=${AWS_REGION}

For example:
  gh variable set AZURE_APPLY_CLIENT_ID --repo ${OWNER}/${REPO} --body "${AZURE_APPLY_CLIENT_ID}"
OUT
