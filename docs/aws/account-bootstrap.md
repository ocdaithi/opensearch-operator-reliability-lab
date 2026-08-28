# AWS account bootstrap

This is the canonical runbook for a fresh installation of the AWS account
foundation. Use
[Verify the Terraform-managed AWS foundation](verify-state.md) for routine
verification. Other documents explain the design and recovery boundaries but
do not define an alternative fresh-install command sequence.

The fresh-install path is only for an account with no foundation state. The
existing lab account already uses the S3 backend. Never run the local-first
migration against that installation.

Before using this branch against the existing installation, follow the
[one-off compatibility check](verify-state.md#one-off-compatibility-check-for-the-existing-installation).
Preserve its ignored `backend.tf` and cached backend configuration for that
first zero-change plan.

The account foundation is applied manually from an exact saved plan. GitHub
Actions validates the source without AWS credentials and provides a separate
OIDC smoke test. It does not apply this foundation.

## Requirements

Use a trusted local workstation with an accurate clock and encrypted storage.
Run commands from the repository root in an interactive macOS zsh session. The
required tools are:

- Git;
- Terraform 1.15.9, as constrained by `infra/bootstrap/versions.tf`;
- AWS CLI 2.32.0 or later with `aws login` support;
- `jq`;
- GitHub CLI for the final OIDC smoke test.

This implementation targets the commercial AWS partition. The pre-Terraform
policies and GitHub OIDC audience are not portable to AWS GovCloud, AWS China or
other partitions without a separate design change.

Use a standalone AWS account while its Free Tier credits remain active. Do not
create or join an AWS Organization or configure AWS Control Tower during that
period. Review the account-plan effect only after the credits are no longer
active. A budget alert is a notification, not a spending cap, and does not stop
resources. [Cost data and notifications can be delayed](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html),
so spend may pass a threshold before the alert arrives.

Before starting, confirm through a root MFA session that:

- the root password is unique and stored securely;
- root MFA and account recovery paths work;
- the root user has no access keys;
- billing and security contact details are current;
- the account ID and selected Region are correct.

Never configure root credentials in the AWS CLI. Use root only for the manual
prerequisites described below, then sign out.

## Inputs and fixed names

Keep all resolved installation values in the ignored private variable file.
The Terraform inputs are:

| Terraform variable          | Local value                   | Future GitHub name                 | Environment placement |
| --------------------------- | ----------------------------- | ---------------------------------- | --------------------- |
| `expected_aws_account_id`   | `<aws-account-id>`            | `TF_VAR_expected_aws_account_id`   | Secret                |
| `aws_region`                | `<aws-region>`                | `TF_VAR_aws_region`                | Variable              |
| `state_bucket_name`         | `<state-bucket-name>`         | `TF_VAR_state_bucket_name`         | Secret                |
| `budget_notification_email` | `<budget-notification-email>` | `TF_VAR_budget_notification_email` | Secret                |
| `github_owner`              | `<github-owner>`              | `TF_VAR_github_owner`              | Variable              |
| `github_owner_id`           | Numeric owner ID              | `TF_VAR_github_owner_id`           | Secret                |
| `github_repository`         | `<github-repository>`         | `TF_VAR_github_repository`         | Variable              |
| `github_repository_id`      | Numeric repository ID         | `TF_VAR_github_repository_id`      | Secret                |
| `github_environment`        | `<github-environment>`        | `TF_VAR_github_environment`        | Variable              |

The numeric GitHub IDs bind OIDC trust to immutable identities rather than
names alone. Obtain them from the relevant GitHub account and repository, and
keep them in the ignored variable file. The tracked example contains synthetic
IDs only.

`opensearch-lab` is the reviewed, portable security-contract prefix. Terraform
derives the predictable user, role, policy and budget names from it. The state
and native lock keys are fixed:

```text
bootstrap/terraform.tfstate
bootstrap/terraform.tfstate.tflock
```

Credentials, profiles and role ARNs are not Terraform inputs.

## 1. Prepare the workstation and private inputs

Keep AWS CLI configuration and login cache data inside the ignored repository
paths already used by this installation. Preserve these paths throughout the
bootstrap and recovery period. In every new shell, run this setup from the
repository root before using the AWS CLI or Terraform:

```zsh
umask 077
test ! -L ".aws" && \
  test ! -L ".aws/login" && \
  test ! -L ".aws/login/cache" && \
  mkdir -p ".aws/login/cache" && \
  chmod 700 ".aws" ".aws/login" ".aws/login/cache" && \
  test ! -L ".aws/config" && \
  test ! -e ".aws/credentials" && \
  test ! -L ".aws/credentials" && \
  export AWS_CONFIG_FILE="$PWD/.aws/config" && \
  export AWS_SHARED_CREDENTIALS_FILE="$PWD/.aws/credentials" && \
  export AWS_LOGIN_CACHE_DIRECTORY="$PWD/.aws/login/cache" && \
  export AWS_EC2_METADATA_DISABLED=true && \
  export AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true
```

Clear credential sources and endpoint overrides that could take precedence
over, or redirect, the named repository-local profiles:

```zsh
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
unset AWS_SECURITY_TOKEN AWS_CREDENTIAL_EXPIRATION
unset AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME
unset AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
unset AWS_CONTAINER_CREDENTIALS_FULL_URI
unset AWS_CONTAINER_AUTHORIZATION_TOKEN
unset AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE
unset AWS_ENDPOINT_URL AWS_ENDPOINT_URL_STS AWS_ENDPOINT_URL_S3
unset AWS_ENDPOINT_URL_IAM AWS_ENDPOINT_URL_BUDGETS
unset AWS_S3_ENDPOINT AWS_STS_ENDPOINT AWS_IAM_ENDPOINT
unset AWS_BUDGETS_ENDPOINT
unset AWS_PROFILE AWS_DEFAULT_PROFILE
unset TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_plan
unset TF_CLI_ARGS_apply TF_CLI_ARGS_state TF_CLI_ARGS_show
unset TF_CLI_ARGS_output TF_DATA_DIR TF_WORKSPACE
unset TF_VAR_terraform_admin_role_arn
```

Do not delete or replace an existing repository-local configuration or login
cache. The shared credentials path should remain absent because authentication
comes from `aws login`, but retaining the path variable prevents fallback to a
user-wide credentials file. Stop if the repository-local configuration contains
a custom service endpoint.

Create the private working directory and copy the synthetic example. Stop if
either destination already exists, including as a symlink.

```zsh
module_dir="infra/bootstrap"
private_dir=".private/terraform-bootstrap"
tfvars_file="${private_dir}/terraform.tfvars"
plan_file="${private_dir}/account-foundation.tfplan"

test ! -L ".private" && \
  test ! -e "${private_dir}" && \
  test ! -L "${private_dir}" && \
  test ! -e "${tfvars_file}" && \
  test ! -L "${tfvars_file}" && \
  mkdir -p "${private_dir}" && \
  chmod 700 ".private" "${private_dir}" && \
  cp "${module_dir}/terraform.tfvars.example" "${tfvars_file}" && \
  chmod 600 "${tfvars_file}" && \
  printf 'Created %s; edit every synthetic value before continuing.\n' \
    "${tfvars_file}"
```

Replace every synthetic value. Do not add credentials, profile names or role
ARNs. `budget_notification_email` is marked sensitive to reduce incidental CLI
display, but its value can still appear in Terraform state and saved plans.

Read the two private values needed by the policy renderers without placing them
in shell history. They must exactly match the private variable file.

```zsh
read -rs "aws_account_id?Expected 12-digit AWS account ID: "
printf '\n' >&2
read -rs "state_bucket_name?Exact Terraform state bucket name: "
printf '\n' >&2
read -r "aws_region?AWS Region from the private variable file: "
```

## 2. Create the durable permissions boundaries

Render the two reviewed templates to new private files. The renderer refuses
overwrites and symlink destinations.

```bash
"${module_dir}/scripts/generate-permissions-boundaries.sh" \
  "${aws_account_id}" \
  "${state_bucket_name}" \
  "${private_dir}/terraform-admin-boundary.json" \
  "${private_dir}/github-actions-boundary.json"

jq . "${private_dir}/terraform-admin-boundary.json"
jq . "${private_dir}/github-actions-boundary.json"
```

Review both resolved policies locally against their tracked templates. Do not
paste the output into an issue, workflow log or commit.

In the AWS console, using the root MFA session:

1. Confirm that the exact intended user, roles, OIDC provider, budget, state
   bucket and customer-managed policies do not already exist. An access-denied
   response is not proof of absence.
2. Create the IAM user `opensearch-lab-bootstrap` at path `/` with console
   sign-in and MFA.
3. Attach only the AWS-managed `SignInLocalDevelopmentAccess` policy. Do not
   add access keys, groups, inline policies or a permissions boundary.
4. Create `opensearch-lab-terraform-admin-boundary` from the reviewed Terraform
   administration boundary.
5. Create `opensearch-lab-github-actions-boundary` from the reviewed GitHub
   Actions boundary.

These allow-only boundaries are durable root-created controls. Do not attach
them to the bootstrap user. Terraform references them but cannot change their
contents or default versions.

In GitHub, create `<github-environment>` outside Terraform. Restrict deployment
to the protected `main` branch and exclude tags and untrusted pull-request
contexts. Record the owner and repository numeric IDs in the private tfvars.
Repository and Environment settings remain manual controls.

## 3. Grant four-hour bootstrap access

Generate the temporary policy only when the operator, root session and review
window are ready. It contains one literal UTC expiry four hours after creation
and is bound to the exact bootstrap principal and its sign-in session.

```bash
"${module_dir}/scripts/generate-temporary-policy.sh" \
  "${aws_account_id}" \
  "${state_bucket_name}" \
  "${private_dir}/temporary-bootstrap-policy.json"

jq . "${private_dir}/temporary-bootstrap-policy.json"
```

Review it locally. In the root console, create the customer-managed policy
`opensearch-lab-temporary-bootstrap` from that file and attach it only to
`opensearch-lab-bootstrap`. Sign out of root.

Do not edit the expiry, create a new policy version to extend it or regenerate
the document while an earlier temporary policy is attached. If the window
expires, stop and use the recovery guide.

## 4. Authenticate with `aws login`

The profile contains login configuration, not access keys. Complete the browser
flow as the exact bootstrap user and its MFA-protected sign-in session.

```bash
aws configure set region "${aws_region}" --profile opensearch-lab-terraform
aws configure set output json --profile opensearch-lab-terraform
aws login --profile opensearch-lab-terraform --region "${aws_region}"
```

Confirm the configured login principal, credential source and caller identity
without printing the account identity.

```bash
test "$(aws configure get login_session \
  --profile opensearch-lab-terraform)" = \
  "arn:aws:iam::${aws_account_id}:user/opensearch-lab-bootstrap"

credential_resolution="$(aws configure list \
  --profile opensearch-lab-terraform)"
test "$(grep -Ec \
  '^[[:space:]]*(access_key|secret_key).*login' \
  <<<"${credential_resolution}")" -eq 2

aws --profile opensearch-lab-terraform sts get-caller-identity \
  --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    .Arn == ("arn:aws:iam::" + $account +
      ":user/opensearch-lab-bootstrap")
  ' >/dev/null
unset credential_resolution
```

Stop if the identity differs or the credential source is not `login`. Do not
fall back to access keys or an ambient default profile.

## 5. Initialise temporary local state

The ignored local backend writes state only below the private directory. Stop
if `backend.tf` or `.terraform` already exists. Existing backend metadata may
identify the live S3 installation. Do not delete it to make the fresh-install
path proceed. Use the routine S3 path instead.

```bash
test ! -e "${module_dir}/backend.tf" && \
  test ! -L "${module_dir}/backend.tf" && \
  test ! -e "${module_dir}/.terraform" && \
  test ! -L "${module_dir}/.terraform" && \
  cp "${module_dir}/backend.local.tf.example" \
    "${module_dir}/backend.tf" && \
  chmod 600 "${module_dir}/backend.tf" && \
  AWS_PROFILE=opensearch-lab-terraform \
    aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    .Arn == ("arn:aws:iam::" + $account +
      ":user/opensearch-lab-bootstrap")
  ' >/dev/null && \
  AWS_PROFILE=opensearch-lab-terraform \
    terraform -chdir="${module_dir}" init
fresh_init_exit=$?
printf 'Guarded fresh initialisation result: %s\n' "${fresh_init_exit}"
test "${fresh_init_exit}" -eq 0
```

Do not use this local backend on the existing installation or on any stack that
already has remote state.

## 6. Review and apply the exact saved plan

Create one plan inside the ignored private directory. Terraform verifies the
configured account through `allowed_account_ids` before planning resources.
That provider setting prevents a cross-account mistake. It does not prove that
the caller is the intended same-account user or role, so require the exact
bootstrap IAM user immediately before the fresh plan.

```bash
test "${fresh_init_exit:-125}" -eq 0 && \
  test ! -e "${plan_file}" && \
  test ! -L "${plan_file}" && \
  AWS_PROFILE=opensearch-lab-terraform \
    aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    .Arn == ("arn:aws:iam::" + $account +
      ":user/opensearch-lab-bootstrap")
  ' >/dev/null && \
  AWS_PROFILE=opensearch-lab-terraform \
    terraform -chdir="${module_dir}" plan \
    -var-file="../../${tfvars_file}" \
    -out="../../${plan_file}" && \
  chmod 600 "${plan_file}" && \
  terraform -chdir="${module_dir}" show \
    -no-color "../../${plan_file}"
fresh_plan_exit=$?
test "${fresh_plan_exit}" -ne 0 || fresh_init_exit=125
printf 'Guarded fresh-plan result: %s\n' "${fresh_plan_exit}"
test "${fresh_plan_exit}" -eq 0
```

Review every create, resolved identity, trust condition, permissions boundary,
budget notification and state-bucket control. Stop on any unexpected existing
resource, update, replacement or deletion. A saved plan can contain private
values even when variables are marked sensitive, so keep the review local.

Apply that exact file. Do not run an unsaved apply, use `-target` or substitute a
new plan after review.

```bash
test "${fresh_plan_exit:-125}" -eq 0 && \
  fresh_plan_exit=125 && \
  AWS_PROFILE=opensearch-lab-terraform \
  aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    .Arn == ("arn:aws:iam::" + $account +
      ":user/opensearch-lab-bootstrap")
  ' >/dev/null && \
  AWS_PROFILE=opensearch-lab-terraform \
    terraform -chdir="${module_dir}" apply \
    "../../${plan_file}"
fresh_apply_exit=$?
printf 'Guarded fresh-apply result: %s\n' "${fresh_apply_exit}"
test "${fresh_apply_exit}" -eq 0
```

If apply fails, preserve the plan, local state, backend declaration and backend
metadata. Do not migrate or retry blindly.

## 7. Configure the administration-role profile

Capture the role output without displaying it. Configure an ordinary AWS CLI
role profile whose source is the `aws login` profile.

```bash
test "${fresh_apply_exit:-125}" -eq 0 && \
  admin_role_arn="$(
  AWS_PROFILE=opensearch-lab-terraform \
    terraform -chdir="${module_dir}" output \
    -raw terraform_admin_role_arn
)" && \
  aws configure set role_arn "${admin_role_arn}" \
    --profile opensearch-lab-admin && \
  aws configure set source_profile opensearch-lab-terraform \
    --profile opensearch-lab-admin && \
  aws configure set role_session_name terraform-foundation-management \
    --profile opensearch-lab-admin && \
  aws configure set region "${aws_region}" \
    --profile opensearch-lab-admin && \
  aws configure set output json --profile opensearch-lab-admin && \
  aws --profile opensearch-lab-admin sts get-caller-identity \
    --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    (.Arn | test("^arn:aws:sts::" + $account +
      ":assumed-role/opensearch-lab-terraform-admin/[^/]+$"))
  ' >/dev/null
admin_profile_exit=$?
printf 'Administration-profile result: %s\n' "${admin_profile_exit}"
test "${admin_profile_exit}" -eq 0
```

The backend and provider will now use the same normal AWS SDK credential chain
through `AWS_PROFILE=opensearch-lab-admin`. The role ARN is not a Terraform
variable. The identity check fixes the account and role name while accepting
the profile's non-empty STS session suffix. An existing installation may retain
its already reviewed role session name without changing the selected role.

## 8. Preserve migration recovery material

Read the created bucket name from Terraform without displaying it, require it
to match the reviewed renderer input, and preserve private copies of the local
state, backend declaration and backend metadata. The destination must be new.

```bash
recovery_dir="${private_dir}/pre-migration-recovery"
test "${fresh_apply_exit:-125}" -eq 0 && \
  test "${admin_profile_exit:-125}" -eq 0 && \
  created_state_bucket="$(
  AWS_PROFILE=opensearch-lab-terraform \
    terraform -chdir="${module_dir}" output -raw state_bucket_name
)" && \
  test "${created_state_bucket}" = "${state_bucket_name}" && \
  test ! -e "${recovery_dir}" && \
  test ! -L "${recovery_dir}" && \
  mkdir "${recovery_dir}" && \
  chmod 700 "${recovery_dir}" && \
  install -m 600 "${private_dir}/terraform.tfstate" \
    "${recovery_dir}/local.tfstate" && \
  install -m 600 "${module_dir}/backend.tf" \
    "${recovery_dir}/backend.tf" && \
  install -m 600 "${module_dir}/.terraform/terraform.tfstate" \
    "${recovery_dir}/backend-metadata.tfstate"
recovery_copy_exit=$?
printf 'Recovery copy result: %s\n' "${recovery_copy_exit}"
test "${recovery_copy_exit}" -eq 0
```

Keep these files unchanged until the refreshed remote plan in the next section
returns exit code `0`.

## 9. Migrate natively to S3

Replace the ignored local declaration with the tracked partial S3 backend. The
tracked file deliberately contains no bucket, Region, profile or credentials.

Use Terraform's native migration with every backend setting explicit. Read the
prompt, confirm that it describes copying the existing local state to S3, then
accept it.

```bash
test "${recovery_copy_exit:-125}" -eq 0 && \
  recovery_copy_exit=125 && \
  cp "${module_dir}/backend.s3.tf.example" \
    "${module_dir}/backend.tf" && \
  chmod 600 "${module_dir}/backend.tf" && \
  AWS_PROFILE=opensearch-lab-admin \
    aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    (.Arn | test("^arn:aws:sts::" + $account +
      ":assumed-role/opensearch-lab-terraform-admin/[^/]+$"))
  ' >/dev/null && \
  AWS_PROFILE=opensearch-lab-admin \
    terraform -chdir="${module_dir}" init -migrate-state \
    -backend-config="bucket=${created_state_bucket}" \
    -backend-config="key=bootstrap/terraform.tfstate" \
    -backend-config="region=${aws_region}" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true"
migration_exit=$?
printf 'Guarded migration result: %s\n' "${migration_exit}"
test "${migration_exit}" -eq 0
```

Do not add migration flags or bypass Terraform's native process. If the result
is unclear, preserve all files and follow the recovery guide.

Run a normal refresh-enabled plan through the administration role. Exit code
`0` is required. Exit code `2` means drift or configuration change, and exit
code `1` means an error. Neither is success.

```bash
test "${migration_exit:-125}" -eq 0 && \
  AWS_PROFILE=opensearch-lab-admin \
  aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    (.Arn | test("^arn:aws:sts::" + $account +
      ":assumed-role/opensearch-lab-terraform-admin/[^/]+$"))
  ' >/dev/null && \
  AWS_PROFILE=opensearch-lab-admin \
    terraform -chdir="${module_dir}" plan \
    -var-file="../../${tfvars_file}" \
    -detailed-exitcode
post_migration_exit=$?
printf 'Guarded post-migration check result: %s\n' \
  "${post_migration_exit}"
test "${post_migration_exit}" -eq 0 && rm -- "${plan_file}"
```

Result `0` means that the prerequisite, exact-role check and zero-change plan
all passed. Result `2` means the plan found drift or configuration change.
Result `1` can mean a failed prerequisite, identity mismatch or Terraform
error. Do not remove temporary access or recovery material unless the result is
`0`. After it passes, the saved account-foundation plan is removed. Never
upload a saved plan to GitHub.

The S3 backend is now authoritative. Terraform continues to manage its own
bucket. Versioning, SSE-S3, public-access blocking, `BucketOwnerEnforced`, the
HTTPS-only bucket policy, non-current-version retention, `force_destroy = false`
and `prevent_destroy` remain part of the reviewed configuration.

## 10. Read back the durable boundaries

Use the administration role to retrieve each live default policy version into
the private directory and compare its JSON structure with the reviewed local
document.

```bash
admin_boundary_arn="arn:aws:iam::${aws_account_id}:policy/opensearch-lab-terraform-admin-boundary"
admin_boundary_version="$(aws --profile opensearch-lab-admin \
  iam get-policy --policy-arn "${admin_boundary_arn}" \
  --query 'Policy.DefaultVersionId' --output text)" && \
  aws --profile opensearch-lab-admin iam get-policy-version \
  --policy-arn "${admin_boundary_arn}" \
  --version-id "${admin_boundary_version}" \
  --query 'PolicyVersion.Document' --output json \
  >"${private_dir}/terraform-admin-boundary.live.json" && \
  chmod 600 "${private_dir}/terraform-admin-boundary.live.json" && \
  jq -e --slurpfile live \
  "${private_dir}/terraform-admin-boundary.live.json" \
  '. == $live[0]' \
  "${private_dir}/terraform-admin-boundary.json" >/dev/null
admin_boundary_review_exit=$?
printf 'Administration-boundary review result: %s\n' \
  "${admin_boundary_review_exit}"
test "${admin_boundary_review_exit}" -eq 0
```

```bash
github_boundary_arn="arn:aws:iam::${aws_account_id}:policy/opensearch-lab-github-actions-boundary"
test "${admin_boundary_review_exit:-125}" -eq 0 && \
  github_boundary_version="$(aws --profile opensearch-lab-admin \
  iam get-policy --policy-arn "${github_boundary_arn}" \
  --query 'Policy.DefaultVersionId' --output text)" && \
  aws --profile opensearch-lab-admin iam get-policy-version \
  --policy-arn "${github_boundary_arn}" \
  --version-id "${github_boundary_version}" \
  --query 'PolicyVersion.Document' --output json \
  >"${private_dir}/github-actions-boundary.live.json" && \
  chmod 600 "${private_dir}/github-actions-boundary.live.json" && \
  jq -e --slurpfile live \
  "${private_dir}/github-actions-boundary.live.json" \
  '. == $live[0]' \
  "${private_dir}/github-actions-boundary.json" >/dev/null
github_boundary_review_exit=$?
printf 'GitHub-boundary review result: %s\n' \
  "${github_boundary_review_exit}"
test "${github_boundary_review_exit}" -eq 0
```

Confirm that both Terraform-created roles use the exact durable boundary ARNs.

```bash
test "${github_boundary_review_exit:-125}" -eq 0 && \
  aws --profile opensearch-lab-admin iam get-role \
  --role-name opensearch-lab-terraform-admin |
  jq -e --arg boundary "${admin_boundary_arn}" '
    .Role.PermissionsBoundary.PermissionsBoundaryArn == $boundary
  ' >/dev/null && \
  aws --profile opensearch-lab-admin iam get-role \
  --role-name opensearch-lab-github-actions |
  jq -e --arg boundary "${github_boundary_arn}" '
    .Role.PermissionsBoundary.PermissionsBoundaryArn == $boundary
  ' >/dev/null
role_boundary_review_exit=$?
printf 'Role-boundary review result: %s\n' \
  "${role_boundary_review_exit}"
test "${role_boundary_review_exit}" -eq 0
```

Stop on any mismatch. Do not update either boundary as part of this runbook.

## 11. Check bootstrap-user hygiene

Run each explicit check through the administration role. Before temporary
policy removal, the bootstrap user must have no long-lived credential or
inherited permission, and exactly the sign-in and temporary policies attached.

```bash
test "${role_boundary_review_exit:-125}" -eq 0 && \
  aws --profile opensearch-lab-admin iam get-user \
  --user-name opensearch-lab-bootstrap |
  jq -e '
    .User.UserName == "opensearch-lab-bootstrap" and
    .User.Path == "/" and
    (.User | has("PermissionsBoundary") | not)
  ' >/dev/null && \
  aws --profile opensearch-lab-admin iam list-access-keys \
  --user-name opensearch-lab-bootstrap |
  jq -e '.AccessKeyMetadata | length == 0' >/dev/null && \
  aws --profile opensearch-lab-admin iam list-groups-for-user \
  --user-name opensearch-lab-bootstrap |
  jq -e '.Groups | length == 0' >/dev/null && \
  aws --profile opensearch-lab-admin iam list-user-policies \
  --user-name opensearch-lab-bootstrap |
  jq -e '.PolicyNames | length == 0' >/dev/null && \
  aws --profile opensearch-lab-admin iam list-mfa-devices \
  --user-name opensearch-lab-bootstrap |
  jq -e '.MFADevices | length >= 1' >/dev/null
bootstrap_hygiene_exit=$?
printf 'Bootstrap-user hygiene result: %s\n' "${bootstrap_hygiene_exit}"
test "${bootstrap_hygiene_exit}" -eq 0
```

```bash
test "${bootstrap_hygiene_exit:-125}" -eq 0 && \
  aws --profile opensearch-lab-admin iam list-attached-user-policies \
  --user-name opensearch-lab-bootstrap |
  jq -e '
    [.AttachedPolicies[].PolicyName] | sort == [
      "SignInLocalDevelopmentAccess",
      "opensearch-lab-temporary-bootstrap"
    ]
  ' >/dev/null
temporary_attachment_review_exit=$?
printf 'Temporary-policy attachment review result: %s\n' \
  "${temporary_attachment_review_exit}"
test "${temporary_attachment_review_exit}" -eq 0
```

## 12. Remove temporary access

Require the temporary policy to be attached only to the exact bootstrap user,
then detach and delete it through the administration role.

```bash
temporary_policy_arn="arn:aws:iam::${aws_account_id}:policy/opensearch-lab-temporary-bootstrap"
test "${post_migration_exit:-125}" -eq 0 && \
  test "${temporary_attachment_review_exit:-125}" -eq 0 && \
  post_migration_exit=125 && \
  temporary_attachment_review_exit=125 && \
  AWS_PROFILE=opensearch-lab-admin \
  aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    (.Arn | test("^arn:aws:sts::" + $account +
      ":assumed-role/opensearch-lab-terraform-admin/[^/]+$"))
  ' >/dev/null && \
  aws --profile opensearch-lab-admin iam list-entities-for-policy \
  --policy-arn "${temporary_policy_arn}" |
  jq -e '
    [.PolicyUsers[].UserName] == ["opensearch-lab-bootstrap"] and
    (.PolicyGroups | length == 0) and
    (.PolicyRoles | length == 0)
  ' >/dev/null && \
  aws --profile opensearch-lab-admin iam detach-user-policy \
  --user-name opensearch-lab-bootstrap \
  --policy-arn "${temporary_policy_arn}" && \
  aws --profile opensearch-lab-admin iam delete-policy \
  --policy-arn "${temporary_policy_arn}"
temporary_access_removal_exit=$?
printf 'Temporary-access removal result: %s\n' \
  "${temporary_access_removal_exit}"
test "${temporary_access_removal_exit}" -eq 0
```

Repeat the attached-policy and access-key checks. Only the sign-in policy may
remain.

```bash
test "${temporary_access_removal_exit:-125}" -eq 0 && \
  aws --profile opensearch-lab-admin iam list-attached-user-policies \
  --user-name opensearch-lab-bootstrap |
  jq -e '
    [.AttachedPolicies[].PolicyName] == [
      "SignInLocalDevelopmentAccess"
    ]
  ' >/dev/null && \
  aws --profile opensearch-lab-admin iam list-access-keys \
  --user-name opensearch-lab-bootstrap |
  jq -e '.AccessKeyMetadata | length == 0' >/dev/null && \
  rm -- "${private_dir}/temporary-bootstrap-policy.json"
```

Do not remove either durable boundary, the bootstrap user or its login policy.
The user remains the MFA-backed source principal for assuming the Terraform
administration role.

## 13. Verify GitHub OIDC

In `<github-environment>`, set the non-sensitive Environment variable
`TF_VAR_aws_region` to `<aws-region>`. Capture the role ARN without printing it
and store it as the Environment secret `AWS_OIDC_ROLE_ARN`. It is installation
configuration, not an AWS credential.

```bash
gh variable set TF_VAR_aws_region \
  --env "<github-environment>" \
  --repo "<github-owner>/<github-repository>" \
  --body "<aws-region>" && \
  github_actions_role_arn="$(
  AWS_PROFILE=opensearch-lab-admin \
    terraform -chdir="${module_dir}" output \
    -raw github_actions_role_arn
)" && \
  printf '%s' "${github_actions_role_arn}" |
  gh secret set AWS_OIDC_ROLE_ARN \
  --env "<github-environment>" \
  --repo "<github-owner>/<github-repository>"
oidc_configuration_exit=$?
unset github_actions_role_arn
printf 'GitHub OIDC configuration result: %s\n' \
  "${oidc_configuration_exit}"
test "${oidc_configuration_exit}" -eq 0
```

Confirm in GitHub that the Environment still permits only protected `main`, and
that `.github/workflows/verify-aws-oidc.yml` on `main` matches the reviewed
workflow. Dispatch it with the exact Environment input.

```bash
test "${oidc_configuration_exit:-125}" -eq 0 && \
  oidc_configuration_exit=125 && \
  gh workflow run verify-aws-oidc.yml \
  --ref main \
  --repo "<github-owner>/<github-repository>" \
  -f environment="<github-environment>" && \
  gh run list \
  --workflow verify-aws-oidc.yml \
  --branch main \
  --event workflow_dispatch \
  --repo "<github-owner>/<github-repository>" \
  --limit 5
```

Open the matching run and require both `Require the reviewed branch` and
`Verify role assumption` to succeed. The workflow receives an OIDC token and
temporary AWS credentials. It has no stored AWS access key. If dispatch is
indeterminate, inspect existing runs before trying again. Do not recreate the
temporary bootstrap policy to diagnose OIDC.

## Existing S3-backed installation

The existing installation must first prove that this branch describes its live
foundation without changing local backend configuration. Follow
[the one-off compatibility check](verify-state.md#one-off-compatibility-check-for-the-existing-installation)
before using the transition below.

For that first compatibility plan:

- preserve the current ignored `infra/bootstrap/backend.tf` byte for byte;
- preserve `infra/bootstrap/.terraform` and its cached backend configuration;
- do not copy either tracked backend example;
- do not run `terraform init`, `terraform init -reconfigure` or
  `terraform init -migrate-state`;
- require the existing remote state to produce a refreshed zero-change plan
  through the exact administration-role identity.

The existing installation is already S3-backed. It must never run the fresh
local-state migration in section 9.

### Optional local backend transition after compatibility

Only after the compatibility plan returns exit code `0` may an operator review
a separate local transition from the legacy backend role-assumption
configuration to the partial ambient-credential backend. This transition does
not change remote state or AWS configuration. Continue in the same zsh session
used for the compatibility check so its repository-local configuration,
cleared environment, account ID and Region remain selected.

Preserve the working backend declaration and cached backend metadata first:

```zsh
umask 077
module_dir="infra/bootstrap"
private_dir=".private/terraform-bootstrap"
transition_dir="${private_dir}/pre-ambient-backend-transition"
read -rs "state_bucket_name?Exact existing Terraform state bucket name: "
printf '\n' >&2
  test "${compatibility_exit:-125}" -eq 0 && \
  compatibility_exit=125 && \
  test -f "${module_dir}/backend.tf" && \
  test ! -L "${module_dir}/backend.tf" && \
  test -d "${module_dir}/.terraform" && \
  test ! -L "${module_dir}/.terraform" && \
  test -f "${module_dir}/.terraform/terraform.tfstate" && \
  test ! -L "${module_dir}/.terraform/terraform.tfstate" && \
  test ! -e "${transition_dir}" && \
  test ! -L "${transition_dir}" && \
  mkdir "${transition_dir}" && \
  chmod 700 "${transition_dir}" && \
  install -m 600 "${module_dir}/backend.tf" \
    "${transition_dir}/backend.tf" && \
  install -m 600 "${module_dir}/.terraform/terraform.tfstate" \
    "${transition_dir}/backend-metadata.tfstate"
transition_preservation_exit=$?
printf 'Backend preservation result: %s\n' \
  "${transition_preservation_exit}"
test "${transition_preservation_exit}" -eq 0
```

Replace only the ignored declaration, then reconfigure the local working
directory against the same S3 object. Do not use migration mode because the
authoritative state is already in S3.

```zsh
test "${transition_preservation_exit:-125}" -eq 0 && \
  cp "${module_dir}/backend.s3.tf.example" \
    "${module_dir}/backend.tf" && \
  chmod 600 "${module_dir}/backend.tf" && \
  AWS_PROFILE=opensearch-lab-admin \
    aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    (.Arn | test("^arn:aws:sts::" + $account +
      ":assumed-role/opensearch-lab-terraform-admin/[^/]+$"))
  ' >/dev/null && \
  AWS_PROFILE=opensearch-lab-admin \
    terraform -chdir="${module_dir}" init -reconfigure \
    -backend-config="bucket=${state_bucket_name}" \
    -backend-config="key=bootstrap/terraform.tfstate" \
    -backend-config="region=${aws_region}" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true"
backend_reconfiguration_exit=$?
printf 'Guarded backend reconfiguration result: %s\n' \
  "${backend_reconfiguration_exit}"
test "${backend_reconfiguration_exit}" -eq 0
```

Require another refreshed zero-change plan before accepting the local
transition. After reconfiguration succeeds, run the canonical
[routine S3-backed verification](verify-state.md#routine-s3-backed-verification).
Retain the preserved files until that verification returns exit code `0`.

## Routine foundation changes

The foundation remains a local, human-reviewed operation. First run the
canonical [routine S3-backed verification](verify-state.md#routine-s3-backed-verification)
and require exit code `0`. Continue in that zsh session without clearing its
environment. The administration role can apply only changes allowed by its
durable boundary and inline policy. Changes to IAM identity, OIDC trust, the
HTTPS-only bucket policy or a durable boundary need a separate root-supervised
bootstrap and security review.

```zsh
module_dir="infra/bootstrap"
private_dir=".private/terraform-bootstrap"
tfvars_file="${private_dir}/terraform.tfvars"
plan_file="${private_dir}/account-foundation.tfplan"
```

Create and review one exact private plan. Never upload the binary plan to
GitHub.

```zsh
test "${routine_verification_exit:-125}" -eq 0 && \
  routine_apply_exit=125 && \
  test ! -e "${plan_file}" && \
  test ! -L "${plan_file}" && \
  AWS_PROFILE=opensearch-lab-admin \
    aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    (.Arn | test("^arn:aws:sts::" + $account +
      ":assumed-role/opensearch-lab-terraform-admin/[^/]+$"))
  ' >/dev/null && \
  AWS_PROFILE=opensearch-lab-admin \
    terraform -chdir="${module_dir}" plan \
    -var-file="../../${tfvars_file}" \
    -out="../../${plan_file}" && \
  chmod 600 "${plan_file}" && \
  terraform -chdir="${module_dir}" show \
    -no-color "../../${plan_file}"
routine_change_plan_exit=$?
printf 'Guarded routine-plan result: %s\n' \
  "${routine_change_plan_exit}"
test "${routine_change_plan_exit}" -eq 0
```

Apply only the reviewed saved plan, after checking the exact role again.

```zsh
test "${routine_change_plan_exit:-125}" -eq 0 && \
  routine_change_plan_exit=125 && \
  routine_verification_exit=125 && \
  AWS_PROFILE=opensearch-lab-admin \
  aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    (.Arn | test("^arn:aws:sts::" + $account +
      ":assumed-role/opensearch-lab-terraform-admin/[^/]+$"))
  ' >/dev/null && \
  AWS_PROFILE=opensearch-lab-admin \
    terraform -chdir="${module_dir}" apply \
    "../../${plan_file}"
routine_apply_exit=$?
printf 'Guarded routine apply result: %s\n' "${routine_apply_exit}"
test "${routine_apply_exit}" -eq 0
```

After a successful apply, rerun the canonical
[routine S3-backed verification](verify-state.md#routine-s3-backed-verification).
It performs a new exact-role check and refresh-enabled plan. Remove the saved
plan only after that verification records exit code `0`.

```zsh
test "${routine_apply_exit:-125}" -eq 0 && \
  test "${routine_verification_exit:-125}" -eq 0 && \
  rm -- "${plan_file}"
```

## Current and future automation boundaries

GitHub Actions currently performs credential-free formatting, validation,
mocked Terraform tests, renderer tests and repository security checks. The OIDC
smoke workflow separately proves federation. Automated foundation apply is
deferred.

Any future Terraform workflow must use GitHub OIDC to assume its reviewed
execution role before invoking Terraform. The resulting temporary credentials
become ambient credentials for both the S3 backend and provider, so neither
requires an `assume_role` block. The current GitHub Actions role is deliberately
limited to state and lock access and cannot apply the foundation. Expanding or
replacing that execution identity requires a separate design review.

A future EKS workflow may create a plan from protected `main`, place the exact
binary plan in a private short-lived S3 object, publish only a redacted summary,
require protected Environment approval, download and apply that exact plan, and
rely on lifecycle deletion. That design is planned and is not implemented here.

Argo CD is also planned. It will reconcile Kubernetes workloads only after EKS
exists. It will not manage Terraform infrastructure.

For failures, use [Account bootstrap recovery](account-bootstrap-recovery.md).
For rationale and trust boundaries, see [Bootstrap security and design](bootstrap-security.md).

## Primary references

- [AWS root user best practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)
- [AWS CLI sign-in with `aws login`](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
- [AWS IAM permissions boundaries](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)
- [AWS Free Tier plans](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html)
- [AWS Budgets best practices](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html)
- [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)
- [Terraform backend initialisation](https://developer.hashicorp.com/terraform/cli/commands/init)
- [Terraform saved plan application](https://developer.hashicorp.com/terraform/cli/commands/apply#saved-plan-mode)
- [GitHub OIDC in AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
- [GitHub deployment environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
