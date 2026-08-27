# AWS account bootstrap

This page records the verified account baseline and separates it from planned project controls.

## Secure Free Plan baseline

The lab uses a standalone personal AWS account on the [Free Plan](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html) with AWS Free Tier credits. [ADR 0001](../adr/0001-use-a-standalone-aws-account.md) is the canonical explanation of this account boundary. Staying outside AWS Organizations and AWS Control Tower avoids their documented immediate-expiry path; it does not extend the credits or prevent their consumption.

No AWS infrastructure has been provisioned.

### Root identity

The root user has a dedicated private mailbox so root, billing and security messages remain separate from public project contact channels. It is reserved for root-only and recovery tasks, in line with [AWS root-user best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html).

The root password is unique and securely stored to avoid credential reuse. Two independently stored MFA methods were registered and tested so one unavailable method does not remove the second sign-in path. Recovery details are current. No root access keys exist, avoiding permanent programmatic credentials with unrestricted access. Root was signed out after verification to end the privileged session.

### Free Plan lifecycle

The Free Plan ends after six months or when the AWS Free Tier credits are exhausted, whichever occurs first. The actual credit balance and plan dates remain private.

Account identifiers, account-specific ARNs, private contact and recovery information, MFA products and device names, credentials, and screenshots or other account-specific evidence are also deliberately excluded from this public record.

## Project-specific configuration

No project-specific AWS resource has been configured.

### Human and automation access

Daily human access and automated trust have not been configured.

The initial Terraform bootstrap will run locally with temporary human credentials. GitHub Actions cannot assume an AWS role until the bootstrap has created the OIDC provider and trusted role. The same bootstrap will create the Terraform backend required for routine runs. Temporary human credentials avoid creating a long-lived access key solely to establish automation.

Routine provisioning will then move to GitHub Actions OIDC. Provisioning workflows will obtain short-lived credentials instead of storing AWS credentials in GitHub. The human access model, OIDC provider and role, Terraform backend and EKS infrastructure do not yet exist.

## Bootstrap runbook

Run this initial sequence from the repository root in one dedicated Bash shell. It requires Git, Terraform 1.15.9, `jq`, `less`, GitHub CLI and AWS CLI 2.32.0 or later. AWS documents both the [`aws login` profile](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html) and the [`source_profile` role pattern](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-role.html).

The two AWS profiles have distinct purposes:

| Profile | Purpose |
| --- | --- |
| `opensearch-lab-terraform` | The `aws login` session for the keyless, MFA-protected IAM user `opensearch-lab-bootstrap`. Initial Terraform and the S3 backend use this profile. |
| `opensearch-lab-admin` | An AWS CLI role profile for `opensearch-lab-terraform-admin`, with `opensearch-lab-terraform` as its `source_profile`. Direct verification and temporary-policy removal use this profile. |

Never use `aws configure` to create access keys, `sts get-session-token`, an ambient default profile or `set -x`. Stop on any failed command, unexpected existing object, identity mismatch, plan mismatch or expired permission. An `AccessDenied` response does not prove that a resource is absent.

### 1. Prepare private local files

The commands below refuse to overwrite a previous bootstrap. If any guarded path exists, stop and establish whether this is a new bootstrap or a separately reviewed recovery before changing it.

```bash
set -euo pipefail
umask 077

repository_root="$(git rev-parse --show-toplevel)"
[[ "${PWD}" == "${repository_root}" ]]
private_root="${repository_root}/.private"
private_dir="${private_root}/terraform-bootstrap"
module_dir="${repository_root}/infra/bootstrap"
aws_dir="${repository_root}/.aws"

[[ -d "${module_dir}" && ! -L "${module_dir}" ]]
[[ -f "${module_dir}/backend.local.tf.example" && \
  ! -L "${module_dir}/backend.local.tf.example" ]]
[[ ! -L "${private_root}" ]]
[[ ! -e "${private_dir}" && ! -L "${private_dir}" ]]
[[ ! -e "${aws_dir}" && ! -L "${aws_dir}" ]]
[[ ! -e "${module_dir}/backend.tf" && ! -L "${module_dir}/backend.tf" ]]

mkdir -p "${private_dir}" "${aws_dir}/login/cache"
[[ -d "${private_root}" && ! -L "${private_root}" && -O "${private_root}" ]]
[[ -d "${private_dir}" && ! -L "${private_dir}" && -O "${private_dir}" ]]
[[ -d "${aws_dir}" && ! -L "${aws_dir}" && -O "${aws_dir}" ]]
[[ -d "${aws_dir}/login" && ! -L "${aws_dir}/login" && -O "${aws_dir}/login" ]]
[[ -d "${aws_dir}/login/cache" && ! -L "${aws_dir}/login/cache" && \
  -O "${aws_dir}/login/cache" ]]
chmod 700 "${private_dir}" "${aws_dir}" "${aws_dir}/login" "${aws_dir}/login/cache"
cp "${module_dir}/backend.local.tf.example" "${module_dir}/backend.tf"
chmod 600 "${module_dir}/backend.tf"

read -rsp 'Private budget notification email: ' BUDGET_NOTIFICATION_EMAIL
printf '\n' >&2
read -rsp 'Confirm private budget notification email: ' budget_email_confirmation
printf '\n' >&2
[[ "${BUDGET_NOTIFICATION_EMAIL}" == "${budget_email_confirmation}" ]]
unset budget_email_confirmation
jq -nr --arg email "${BUDGET_NOTIFICATION_EMAIL}" \
  '$email | @json | "budget_notification_email = \(.)"' \
  >"${private_dir}/terraform.tfvars"
chmod 600 "${private_dir}/terraform.tfvars"

unset TF_VAR_terraform_admin_role_arn
unset TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_plan TF_CLI_ARGS_apply
unset TF_CLI_ARGS_show TF_CLI_ARGS_output TF_CLI_ARGS_workspace TF_CLI_ARGS_state
unset TF_WORKSPACE TF_DATA_DIR TF_PLUGIN_CACHE_DIR
unset TF_LOG TF_LOG_PATH TF_LOG_CORE TF_LOG_PROVIDER TF_LOG_SDK
unset TF_LOG_SDK_PROTO TF_LOG_SDK_PROTO_DATA_DIR TF_REATTACH_PROVIDERS
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME
unset AWS_WEB_IDENTITY_TOKEN_FILE
unset AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
unset AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
unset AWS_ENDPOINT_URL AWS_ENDPOINT_URL_STS AWS_ENDPOINT_URL_IAM
unset AWS_ENDPOINT_URL_S3 AWS_ENDPOINT_URL_BUDGETS
unset AWS_REGION AWS_DEFAULT_REGION
export AWS_EC2_METADATA_DISABLED=true

[[ ! -e "${module_dir}/terraform.tfvars" && \
  ! -L "${module_dir}/terraform.tfvars" ]]
[[ ! -e "${module_dir}/terraform.tfvars.json" && \
  ! -L "${module_dir}/terraform.tfvars.json" ]]
shopt -s nullglob
auto_variable_files=(
  "${module_dir}"/*.auto.tfvars
  "${module_dir}"/*.auto.tfvars.json
)
shopt -u nullglob
[[ "${#auto_variable_files[@]}" == '0' ]]
unset auto_variable_files

if grep -Eq '^[[:space:]]*terraform_admin_role_arn[[:space:]]*=' \
  "${private_dir}/terraform.tfvars"; then
  echo 'The administration-role ARN must be absent from the initial variables.' >&2
  exit 1
fi

"${module_dir}/scripts/check-backend-contract.sh" \
  local "${module_dir}/backend.tf" >/dev/null
git check-ignore -q -- "${module_dir}/backend.tf"
git check-ignore -q -- "${private_dir}/terraform.tfvars"
git check-ignore -q -- "${aws_dir}/config"

export AWS_CONFIG_FILE="${aws_dir}/config"
export AWS_SHARED_CREDENTIALS_FILE="${aws_dir}/credentials"
export AWS_LOGIN_CACHE_DIRECTORY="${aws_dir}/login/cache"
```

Keep those three AWS path variables set in every shell used for this bootstrap. They isolate the shared configuration, access-key file path and `aws login` cache under ignored repository paths. AWS CLI role profiles still use the documented assumed-role cache at `~/.aws/cli/cache`; treat that cache as private. `terraform_admin_role_arn` must remain unset for the initial apply and must not be added to the initial private tfvars.

### 2. Generate and review both permissions boundaries

Enter the account ID without putting it in shell history. The generator takes no arguments and writes two mode-600 files below the ignored private directory.

```bash
read -rsp 'AWS account ID: ' AWS_ACCOUNT_ID
printf '\n' >&2
[[ "${AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]]
export AWS_ACCOUNT_ID

[[ ! -e "${private_dir}/terraform-admin-boundary.json" && \
  ! -L "${private_dir}/terraform-admin-boundary.json" ]]
[[ ! -e "${private_dir}/github-actions-boundary.json" && \
  ! -L "${private_dir}/github-actions-boundary.json" ]]
"${module_dir}/scripts/generate-permissions-boundaries.sh"

jq --color-output . \
  "${private_dir}/terraform-admin-boundary.json" | less -R
jq --color-output . \
  "${private_dir}/github-actions-boundary.json" | less -R
```

Review both resolved documents locally against their tracked templates. This necessary local review shows account-specific ARNs, so do not copy its output into logs, issues or commits. Stop if either document differs from the reviewed resource and action allow-lists.

### 3. Complete root-account prerequisites

Use the AWS console with a root MFA session. Do not configure root CLI credentials. Before creating anything, prove that every exact bootstrap target below is absent:

- S3 bucket `opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1`;
- IAM roles `opensearch-lab-terraform-admin` and `opensearch-lab-github-actions`;
- IAM OIDC provider `token.actions.githubusercontent.com`;
- budget `opensearch-lab-monthly-cost`;
- customer-managed policies `opensearch-lab-terraform-admin-boundary`, `opensearch-lab-github-actions-boundary` and `opensearch-lab-temporary-bootstrap`.

Stop if any target exists. Do not import, adopt, overwrite, delete or repurpose it as part of this runbook.

Create or verify the IAM user `opensearch-lab-bootstrap`. It must have console sign-in and a live MFA device, no access keys, no group membership, no inline policy and no user permissions boundary. At this point its only attached policy must be the AWS-managed `SignInLocalDevelopmentAccess` policy required by `aws login`.

Create the following customer-managed policies from the two private documents, preserving the exact names and contents:

- `opensearch-lab-terraform-admin-boundary` from `.private/terraform-bootstrap/terraform-admin-boundary.json`;
- `opensearch-lab-github-actions-boundary` from `.private/terraform-bootstrap/github-actions-boundary.json`.

These two boundary policies are durable root-created prerequisites. They are not Terraform resources, must not be attached to the bootstrap user and must remain after temporary-policy cleanup. Keep the two resolved private documents because both verifier phases compare them with the tracked templates and live policies.

In GitHub, create the Environment `aws-bootstrap`, choose `Selected branches and tags`, add only the branch rule `main` and add no tag rule. Confirm that forks and other untrusted pull request code cannot receive its secrets. Do not add the role secret yet because the role does not exist. GitHub documents that an [environment subject contains the environment rather than a branch](https://docs.github.com/en/actions/reference/security/oidc#example-subject-claims), so the [Environment deployment-branch rule](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments#deployment-branches-and-tags) is the authoritative branch boundary. The workflow's tokenless `main` guard is an additional repository control.

### 4. Generate, create and attach a fresh four-hour temporary policy

Check that the local clock is accurate. Generate this document only when the root session, reviewed Terraform plan workflow and operator are ready to proceed:

```bash
[[ ! -e "${private_dir}/temporary-bootstrap-policy.json" && \
  ! -L "${private_dir}/temporary-bootstrap-policy.json" ]]
"${module_dir}/scripts/generate-temporary-policy.sh"
jq --color-output . \
  "${private_dir}/temporary-bootstrap-policy.json" | less -R
```

The generator embeds one absolute UTC expiry exactly four hours after generation. Review the resolved document locally without copying its account-specific contents elsewhere. In the root console, create the customer-managed policy `opensearch-lab-temporary-bootstrap` from that file and attach it only to `opensearch-lab-bootstrap`. Then sign out of root.

This policy is only for the initial bootstrap or an explicitly reviewed break-glass recovery. It is never used for routine Terraform. Every use requires a newly generated document because the absolute expiry is embedded in every allow statement. Never edit the expiry, extend an old policy, create a new version to refresh it or regenerate while an earlier policy is attached. If an attempt expires or fails, stop and assess any partial state. Remove the old attachment and policy before generating and creating a fresh one for an approved recovery.

### 5. Authenticate the exact bootstrap user

The local AWS CLI must support `aws login`; the command first appeared in AWS CLI 2.32.0. These checks produce no account identifiers:

```bash
aws login help >/dev/null
aws configure set region eu-west-1 --profile opensearch-lab-terraform
aws configure set output json --profile opensearch-lab-terraform
aws login --profile opensearch-lab-terraform --region eu-west-1 >/dev/null
[[ -f "${AWS_CONFIG_FILE}" && ! -L "${AWS_CONFIG_FILE}" && \
  -O "${AWS_CONFIG_FILE}" ]]
chmod 600 "${AWS_CONFIG_FILE}"
[[ ! -e "${AWS_SHARED_CREDENTIALS_FILE}" && \
  ! -L "${AWS_SHARED_CREDENTIALS_FILE}" ]]

login_session="$(
  aws configure get login_session --profile opensearch-lab-terraform
)"
[[ "${login_session}" == \
  "arn:aws:iam::${AWS_ACCOUNT_ID}:user/opensearch-lab-bootstrap" ]]

credential_resolution="$(
  aws configure list --profile opensearch-lab-terraform
)"
[[ "$(grep -Ec \
  '^[[:space:]]*(access_key|secret_key).*login' \
  <<<"${credential_resolution}")" == '2' ]]

caller_identity="$(
  aws --profile opensearch-lab-terraform \
    sts get-caller-identity --output json
)"
jq -e --arg account "${AWS_ACCOUNT_ID}" '
  .Account == $account
  and .Arn == ("arn:aws:iam::" + $account + ":user/opensearch-lab-bootstrap")
' >/dev/null <<<"${caller_identity}"

unset login_session credential_resolution caller_identity AWS_ACCOUNT_ID
```

In the browser flow, select the exact `opensearch-lab-bootstrap` user and complete its MFA challenge. Stop if the selected account or identity differs, the credential source is not `login`, or `.aws/credentials` is created.

### 6. Apply Terraform through the local backend

The initial plan must run as the login user, with the administration-role variable still null. Save the plan only in the private directory and review it locally.

```bash
unset TF_VAR_terraform_admin_role_arn
if grep -Eq '^[[:space:]]*terraform_admin_role_arn[[:space:]]*=' \
  "${private_dir}/terraform.tfvars"; then
  echo 'The administration-role ARN must be absent from the initial variables.' >&2
  exit 1
fi

AWS_PROFILE=opensearch-lab-terraform \
  terraform -chdir="${module_dir}" init -reconfigure -input=false
AWS_PROFILE=opensearch-lab-terraform \
  terraform -chdir="${module_dir}" plan \
  -input=false \
  -var-file="${private_dir}/terraform.tfvars" \
  -out="${private_dir}/initial-bootstrap.tfplan" \
  >/dev/null
chmod 600 "${private_dir}/initial-bootstrap.tfplan"

terraform -chdir="${module_dir}" show -json \
  "${private_dir}/initial-bootstrap.tfplan" |
  jq -e '
    [
      "aws_budgets_budget.account_cost",
      "aws_iam_openid_connect_provider.github",
      "aws_iam_role.github_actions",
      "aws_iam_role.terraform_admin",
      "aws_iam_role_policy.github_actions_state",
      "aws_iam_role_policy.terraform_admin",
      "aws_s3_bucket.state",
      "aws_s3_bucket_lifecycle_configuration.state",
      "aws_s3_bucket_ownership_controls.state",
      "aws_s3_bucket_policy.state",
      "aws_s3_bucket_public_access_block.state",
      "aws_s3_bucket_server_side_encryption_configuration.state",
      "aws_s3_bucket_versioning.state"
    ] as $expected
    | [.resource_changes[] | select(.mode == "managed")] as $managed
    | ($managed | length) == 13
      and all($managed[]; .change.actions == ["create"])
      and ([$managed[].address] | sort) == ($expected | sort)
  ' >/dev/null

terraform -chdir="${module_dir}" show -no-color \
  "${private_dir}/initial-bootstrap.tfplan" | less

AWS_PROFILE=opensearch-lab-terraform \
  terraform -chdir="${module_dir}" apply -input=false \
  "${private_dir}/initial-bootstrap.tfplan" \
  >/dev/null

test -s "${private_dir}/terraform.tfstate"
"${module_dir}/scripts/check-backend-contract.sh" \
  local "${module_dir}/backend.tf" >/dev/null
rm -f "${private_dir}/initial-bootstrap.tfplan"
```

The reviewed plan must contain exactly those 13 creates and no update, delete or replacement. Do not use `-auto-approve`, `-target` or a live apply without the saved plan. If planning or applying fails, preserve the local state and plan, do not rerun blindly and do not proceed to migration.

### 7. Configure the administration role profile

Capture the sensitive Terraform output without displaying it, then create the role profile in the ignored repository-local AWS configuration:

```bash
terraform_admin_role_arn="$(
  AWS_PROFILE=opensearch-lab-terraform \
    terraform -chdir="${module_dir}" output -raw terraform_admin_role_arn
)"
[[ "${terraform_admin_role_arn}" =~ \
  ^arn:aws:iam::[0-9]{12}:role/opensearch-lab-terraform-admin$ ]]

aws configure set role_arn "${terraform_admin_role_arn}" \
  --profile opensearch-lab-admin
aws configure set source_profile opensearch-lab-terraform \
  --profile opensearch-lab-admin
aws configure set role_session_name terraform-bootstrap-management \
  --profile opensearch-lab-admin
aws configure set region eu-west-1 --profile opensearch-lab-admin
aws configure set output json --profile opensearch-lab-admin

[[ "$(aws configure get source_profile --profile opensearch-lab-admin)" == \
  'opensearch-lab-terraform' ]]
[[ "$(aws configure get role_arn --profile opensearch-lab-admin)" == \
  "${terraform_admin_role_arn}" ]]

admin_identity="$(
  aws --profile opensearch-lab-admin sts get-caller-identity --output json
)"
jq -e '
  .Arn | test("^arn:aws:sts::[0-9]{12}:assumed-role/opensearch-lab-terraform-admin/[^/]+$")
' >/dev/null <<<"${admin_identity}"
unset admin_identity terraform_admin_role_arn
```

The admin profile contains no credentials. The CLI obtains its source credentials from the `opensearch-lab-terraform` login session and assumes only `opensearch-lab-terraform-admin`.

### 8. Migrate state

Do not run `render-s3-backend.sh` during this migration flow and do not run `terraform init -migrate-state` manually. The migration script reads the state bucket and administration-role ARN from Terraform output, writes the exact S3 migration backend, proves the remote state and lock keys are empty, migrates and compares state, then injects `TF_VAR_terraform_admin_role_arn` into its own post-migration plan.

```bash
"${module_dir}/scripts/migrate-state.sh" --approved
```

Stop on any error and follow the script's phase-specific diagnostic. If it reports a partial, indeterminate or committed migration, do not restore local state, delete remote objects, force-unlock, replace `backend.tf` or retry. On success, S3 is authoritative and the private pre-migration recovery copy remains for controlled recovery.

The migration keeps its mode-600 recovery and verification files under `.private/terraform-bootstrap/`: `pre-migration-*.tfstate`, `post-migration-*.tfstate`, `pre-migration-backend-*.tf`, an optional `pre-migration-backend-cache-*.tfstate` and `post-migration-lock-check.tfplan`. Never stage, paste or publish these files, the resolved policies, `terraform.tfvars`, `terraform.tfstate`, `infra/bootstrap/backend.tf`, the repository-local `.aws/` directory or the AWS CLI role cache at `~/.aws/cli/cache`.

### 9. Verify before removing temporary access

The verifier requires the exact S3 migration backend, so it must run after migration, never immediately after the initial apply.

```bash
export BUDGET_NOTIFICATION_EMAIL
AWS_PROFILE=opensearch-lab-admin \
  "${module_dir}/scripts/verify-bootstrap-access.sh" --before-removal
```

The email must still be the exact private value written to the initial tfvars. Do not pipe, suppress or ignore the verifier status. If it fails, stop without detaching, deleting, extending or regenerating the temporary policy.

### 10. Detach and delete the temporary policy

Use the verified admin profile and exact names only:

```bash
admin_identity="$(
  aws --profile opensearch-lab-admin sts get-caller-identity --output json
)"
account_id="$(jq -er '.Account | select(test("^[0-9]{12}$"))' \
  <<<"${admin_identity}")"
temporary_policy_arn="arn:aws:iam::${account_id}:policy/opensearch-lab-temporary-bootstrap"

aws --profile opensearch-lab-admin iam detach-user-policy \
  --user-name opensearch-lab-bootstrap \
  --policy-arn "${temporary_policy_arn}"
aws --profile opensearch-lab-admin iam delete-policy \
  --policy-arn "${temporary_policy_arn}"

unset admin_identity account_id temporary_policy_arn
```

Stop if either command fails. Do not remove the login policy, bootstrap user or either durable permissions boundary.

### 11. Verify after removing temporary access

```bash
AWS_PROFILE=opensearch-lab-admin \
  "${module_dir}/scripts/verify-bootstrap-access.sh" --after-removal
rm -f "${private_dir}/temporary-bootstrap-policy.json"
unset BUDGET_NOTIFICATION_EMAIL
```

This phase proves that the temporary managed policy is absent and that the bootstrap user's only attached policy is `SignInLocalDevelopmentAccess`. A failure means cleanup is incomplete. The local resolved temporary document is removed only after that pass so it cannot be reused.

### 12. Configure and dispatch GitHub OIDC verification

First confirm that the reviewed `.github/workflows/verify-aws-oidc.yml` is present on `main` and that the `aws-bootstrap` Environment still admits only `main`. Capture the role ARN without printing it and store it only as the Environment secret `AWS_OIDC_ROLE_ARN`, never as a repository secret:

```bash
gh workflow view verify-aws-oidc.yml \
  --ref main \
  --repo github.com/ocdaithi/opensearch-operator-reliability-lab \
  --yaml >/dev/null

github_actions_role_arn="$(
  AWS_PROFILE=opensearch-lab-terraform \
    terraform -chdir="${module_dir}" output -raw github_actions_role_arn
)"
[[ "${github_actions_role_arn}" =~ \
  ^arn:aws:iam::[0-9]{12}:role/opensearch-lab-github-actions$ ]]
printf '%s' "${github_actions_role_arn}" |
  gh secret set AWS_OIDC_ROLE_ARN \
    --env aws-bootstrap \
    --repo github.com/ocdaithi/opensearch-operator-reliability-lab
unset github_actions_role_arn

dispatch_response="$(
  gh api --method POST \
    --hostname github.com \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    /repos/ocdaithi/opensearch-operator-reliability-lab/actions/workflows/verify-aws-oidc.yml/dispatches \
    -f ref=main \
    -F return_run_details=true
)"
oidc_run_id="$(jq -er '
  .workflow_run_id | select(type == "number" and . > 0) | floor
' <<<"${dispatch_response}")"
jq -e --arg run_id "${oidc_run_id}" '
  .html_url == (
    "https://github.com/ocdaithi/opensearch-operator-reliability-lab/actions/runs/"
    + $run_id
  )
' >/dev/null <<<"${dispatch_response}"

gh run watch "${oidc_run_id}" \
  --exit-status \
  --repo github.com/ocdaithi/opensearch-operator-reliability-lab
oidc_run_json="$(
  gh run view "${oidc_run_id}" \
    --repo github.com/ocdaithi/opensearch-operator-reliability-lab \
    --json headBranch,event,status,conclusion,jobs
)"
jq -e '
  .headBranch == "main"
  and .event == "workflow_dispatch"
  and .status == "completed"
  and .conclusion == "success"
  and ([.jobs[] | {name, conclusion}] | sort_by(.name)) == ([
    {name: "Require the reviewed branch", conclusion: "success"},
    {name: "Verify role assumption", conclusion: "success"}
  ] | sort_by(.name))
' >/dev/null <<<"${oidc_run_json}"
unset dispatch_response oidc_run_id oidc_run_json
```

The versioned [workflow-dispatch endpoint](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event) returns the exact run ID used by the watch and job checks. If the dispatch result is indeterminate, inspect Actions before retrying so a second run is not created blindly. Stop unless both `Require the reviewed branch` and `Verify role assumption` pass; do not recreate or reattach temporary bootstrap access to fix OIDC verification.

### Routine Terraform

For every post-bootstrap Terraform plan or apply, restore the three repository-local AWS path variables, authenticate `opensearch-lab-terraform` with `aws login` if its session has expired, and set the exact administration-role ARN. Use the login profile as the provider source. Using the admin profile while also setting the role variable would attempt to assume the administration role from itself.

One option is a shell variable captured without display:

```bash
repository_root="$(git rev-parse --show-toplevel)"
[[ "${PWD}" == "${repository_root}" ]]
private_dir="${repository_root}/.private/terraform-bootstrap"
module_dir="${repository_root}/infra/bootstrap"
aws_dir="${repository_root}/.aws"
export AWS_CONFIG_FILE="${aws_dir}/config"
export AWS_SHARED_CREDENTIALS_FILE="${aws_dir}/credentials"
export AWS_LOGIN_CACHE_DIRECTORY="${aws_dir}/login/cache"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME
unset AWS_WEB_IDENTITY_TOKEN_FILE
unset AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
unset AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
unset AWS_ENDPOINT_URL AWS_ENDPOINT_URL_STS AWS_ENDPOINT_URL_IAM
unset AWS_ENDPOINT_URL_S3 AWS_ENDPOINT_URL_BUDGETS
unset AWS_REGION AWS_DEFAULT_REGION
export AWS_EC2_METADATA_DISABLED=true
unset TF_VAR_terraform_admin_role_arn
unset TF_CLI_ARGS TF_CLI_ARGS_plan TF_CLI_ARGS_output
unset TF_WORKSPACE TF_DATA_DIR TF_PLUGIN_CACHE_DIR
unset TF_LOG TF_LOG_PATH TF_LOG_CORE TF_LOG_PROVIDER TF_LOG_SDK
unset TF_LOG_SDK_PROTO TF_LOG_SDK_PROTO_DATA_DIR TF_REATTACH_PROVIDERS

terraform_admin_role_arn="$(
  AWS_PROFILE=opensearch-lab-terraform \
    terraform -chdir="${module_dir}" output -raw terraform_admin_role_arn
)"
[[ "${terraform_admin_role_arn}" =~ \
  ^arn:aws:iam::[0-9]{12}:role/opensearch-lab-terraform-admin$ ]]
export TF_VAR_terraform_admin_role_arn="${terraform_admin_role_arn}"
AWS_PROFILE=opensearch-lab-terraform \
  terraform -chdir="${module_dir}" plan \
  -var-file="${private_dir}/terraform.tfvars"
unset TF_VAR_terraform_admin_role_arn terraform_admin_role_arn
```

The alternative is a separate mode-600 private post-bootstrap variable file, such as `.private/terraform-bootstrap/terraform.post-bootstrap.tfvars`, passed after the initial private file. Do not add the role ARN to the initial private tfvars before migration. Routine Terraform never uses `opensearch-lab-temporary-bootstrap`.

Two bounded first-write risks remain accepted during this initial operation. Temporary `s3:PutBucketPolicy` access to the exact bucket can write its policy before Terraform establishes the reviewed TLS-only policy. Temporary `iam:CreateRole` access to the exact roles accepts each initial trust document before the verifier confirms it. The required permissions boundaries cap what a newly created role can do, but they cannot constrain the initial trust-policy contents. The controls above reduce the exposure window; they do not eliminate either race.

### Cost and resource lifecycle

The account, Terraform state, diagnostic evidence and ephemeral resources must be reviewed well before the Free Plan ends or its credits are exhausted. This provides time to decide whether to upgrade, retain durable data and remove temporary resources.

Cost visibility and alerts will be configured before EKS or other material billable resources are created. Durable account bootstrap resources will be kept separate from ephemeral reliability-test resources. These controls are planned, not yet implemented.

## Next checkpoint

Apply and verify the reviewed bootstrap only after the manual prerequisites above are complete.
