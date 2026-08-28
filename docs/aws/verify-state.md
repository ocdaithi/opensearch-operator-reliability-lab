# Verify the Terraform-managed AWS foundation

This is the canonical runbook for routine verification of an S3-backed account
foundation. It also contains the separate one-off compatibility check required
before the existing installation changes its legacy local backend
configuration. Use [AWS account bootstrap](account-bootstrap.md) only for a
fresh installation and reviewed foundation changes.

Both procedures are read-only with respect to managed infrastructure. They use
normal refresh-enabled Terraform plans and require exit code `0`:

- `0` means Terraform found no changes;
- `1` means Terraform returned an error;
- `2` means configuration or refreshed resources differ.

Exit code `2` is evidence to investigate, not authority to apply. A successful
plan includes:

```text
No changes. Your infrastructure matches the configuration.
```

## Prepare the interactive zsh session

Run commands from the repository root on a trusted workstation. Preserve the
existing repository-local AWS configuration, login cache and private Terraform
variables. Do not recreate, replace or inspect private values as part of this
runbook.

Require regular repository-local paths, then restore the environment used by
the AWS CLI and Terraform:

```zsh
umask 077
test -f ".aws/config" && \
  test ! -L ".aws/config" && \
  test -d ".aws/login/cache" && \
  test ! -L ".aws/login/cache" && \
  test ! -e ".aws/credentials" && \
  test ! -L ".aws/credentials" && \
  test -f ".private/terraform-bootstrap/terraform.tfvars" && \
  test ! -L ".private/terraform-bootstrap/terraform.tfvars" && \
  export AWS_CONFIG_FILE="$PWD/.aws/config" && \
  export AWS_SHARED_CREDENTIALS_FILE="$PWD/.aws/credentials" && \
  export AWS_LOGIN_CACHE_DIRECTORY="$PWD/.aws/login/cache" && \
  export AWS_EC2_METADATA_DISABLED=true && \
  export AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true
```

Clear competing credential, endpoint, profile and Terraform command settings
before selecting a profile:

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

Read the expected account and Region from approved local records. The account
prompt is silent so it does not enter shell history or echo to the terminal.

```zsh
read -rs "aws_account_id?Expected 12-digit AWS account ID: "
printf '\n' >&2
read -r "aws_region?AWS Region from the private variable file: "
aws login --profile opensearch-lab-terraform --region "${aws_region}"
```

The `opensearch-lab-admin` profile must already use the login profile as its
source and assume `opensearch-lab-terraform-admin`. Terraform's
`allowed_account_ids` rejects another AWS account, but it does not prove the
exact role within the expected account. Every plan therefore includes a direct
STS guard for this principal shape:

```text
arn:aws:sts::<aws-account-id>:assumed-role/opensearch-lab-terraform-admin/<session-name>
```

## One-off compatibility check for the existing installation

Use this procedure only for the first plan on the existing installation. Its
authoritative state is already in S3, while the ignored backend declaration and
cached backend configuration may still contain the previously reviewed backend
role assumption.

An installation created from `main` may have an ignored, mode-`600` private
tfvars file that uses the former input schema. Before the first compatibility
plan, update the existing `.private/terraform-bootstrap/terraform.tfvars` file
in place to add `expected_aws_account_id`, `aws_region`, `state_bucket_name`,
`github_owner`, `github_owner_id`, `github_repository`,
`github_repository_id` and `github_environment`. Preserve
`budget_notification_email` and every existing deployed value. Obtain each
exact addition from approved existing records. Do not guess a value or treat an
interactive Terraform prompt as a substitute.

Do not overwrite the private file from `terraform.tfvars.example`. Keep it
ignored and at mode `600`; tracked examples must contain placeholders only.
Complete this input reconciliation before running any compatibility command.

Preserve these paths byte for byte:

- `infra/bootstrap/backend.tf`;
- `infra/bootstrap/.terraform`;
- `infra/bootstrap/.terraform/terraform.tfstate`, which is cached backend
  configuration rather than authoritative infrastructure state.

Require them to exist without following symlinks:

```zsh
test -f "infra/bootstrap/backend.tf" && \
  test ! -L "infra/bootstrap/backend.tf" && \
  test -d "infra/bootstrap/.terraform" && \
  test ! -L "infra/bootstrap/.terraform" && \
  test -f "infra/bootstrap/.terraform/terraform.tfstate" && \
  test ! -L "infra/bootstrap/.terraform/terraform.tfstate"
compatibility_preflight_exit=$?
printf 'Compatibility preflight result: %s\n' \
  "${compatibility_preflight_exit}"
test "${compatibility_preflight_exit}" -eq 0
```

Do not copy either backend example or run `terraform init`, `terraform init
-reconfigure` or `terraform init -migrate-state` before this plan. The existing
backend and cache are part of the known working local setup.

Run the exact administration-role check immediately before the compatibility
plan. The `&&` guard prevents Terraform from running if identity verification
fails.

```zsh
test "${compatibility_preflight_exit:-125}" -eq 0 && \
  compatibility_preflight_exit=125 && \
  AWS_PROFILE=opensearch-lab-admin \
  aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    (.Arn | test("^arn:aws:sts::" + $account +
      ":assumed-role/opensearch-lab-terraform-admin/[^/]+$"))
  ' >/dev/null && \
  AWS_PROFILE=opensearch-lab-admin \
    terraform -chdir="infra/bootstrap" plan \
    -detailed-exitcode \
    -var-file="../../.private/terraform-bootstrap/terraform.tfvars"
compatibility_exit=$?
printf 'Guarded compatibility check result: %s\n' "${compatibility_exit}"
test "${compatibility_exit}" -eq 0
```

This plan reads the existing remote state and refreshes managed resources. Do
not add `-refresh=false`, `-out` or `-target`. On any non-zero result, preserve
the backend declaration, cache and private inputs and investigate without
applying or reinitialising.

Result `0` means that the backend preflight, exact-role check and zero-change
plan all passed. Result `2` means the plan found drift or configuration change.
Result `1` can mean a preflight failure, identity mismatch or Terraform error.

After compatibility is proven, keep the legacy backend in place until the
result has been reviewed. Conversion to the partial ambient-credential backend
is a separate local transition. Follow
[Optional local backend transition after compatibility](account-bootstrap.md#optional-local-backend-transition-after-compatibility),
which uses `terraform init -reconfigure` and requires another zero-change plan.

## Routine S3-backed verification

Use this procedure after a fresh installation has migrated successfully, or
after the existing installation has completed its one-off compatibility check
and optional local backend transition. It verifies the current partial S3
backend and private variable file without applying infrastructure.

Require the existing backend declaration and prompt for its exact existing
bucket. Do not replace or edit the backend in this procedure.

```zsh
test -f "infra/bootstrap/backend.tf" && \
  test ! -L "infra/bootstrap/backend.tf" && \
  read -rs "state_bucket_name?Exact existing Terraform state bucket name: " && \
  printf '\n' >&2
routine_backend_preflight_exit=$?
printf 'Routine backend preflight result: %s\n' \
  "${routine_backend_preflight_exit}"
test "${routine_backend_preflight_exit}" -eq 0
```

Check the administration role immediately before normal backend
initialisation. Supply the exact existing bucket, key and Region to the partial
backend.

```zsh
test "${routine_backend_preflight_exit:-125}" -eq 0 && \
  routine_backend_preflight_exit=125 && \
  AWS_PROFILE=opensearch-lab-admin \
  aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    (.Arn | test("^arn:aws:sts::" + $account +
      ":assumed-role/opensearch-lab-terraform-admin/[^/]+$"))
  ' >/dev/null && \
  AWS_PROFILE=opensearch-lab-admin \
    terraform -chdir="infra/bootstrap" init \
    -backend-config="bucket=${state_bucket_name}" \
    -backend-config="key=bootstrap/terraform.tfstate" \
    -backend-config="region=${aws_region}" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true"
routine_init_exit=$?
printf 'Guarded routine initialisation result: %s\n' \
  "${routine_init_exit}"
test "${routine_init_exit}" -eq 0
```

List the Terraform-managed resource addresses from the existing backend:

```zsh
test "${routine_init_exit:-125}" -eq 0 && \
  AWS_PROFILE=opensearch-lab-admin \
  aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    (.Arn | test("^arn:aws:sts::" + $account +
      ":assumed-role/opensearch-lab-terraform-admin/[^/]+$"))
  ' >/dev/null && \
  AWS_PROFILE=opensearch-lab-admin \
    terraform -chdir="infra/bootstrap" state list
routine_state_list_exit=$?
printf 'Guarded state-list result: %s\n' "${routine_state_list_exit}"
test "${routine_state_list_exit}" -eq 0
```

Check the exact administration role again immediately before the routine
refresh-enabled plan:

```zsh
test "${routine_init_exit:-125}" -eq 0 && \
  test "${routine_state_list_exit:-125}" -eq 0 && \
  routine_init_exit=125 && \
  routine_state_list_exit=125 && \
  AWS_PROFILE=opensearch-lab-admin \
  aws sts get-caller-identity --output json |
  jq -e --arg account "${aws_account_id}" '
    .Account == $account and
    (.Arn | test("^arn:aws:sts::" + $account +
      ":assumed-role/opensearch-lab-terraform-admin/[^/]+$"))
  ' >/dev/null && \
  AWS_PROFILE=opensearch-lab-admin \
    terraform -chdir="infra/bootstrap" plan \
    -detailed-exitcode \
    -var-file="../../.private/terraform-bootstrap/terraform.tfvars"
routine_verification_exit=$?
printf 'Guarded routine verification result: %s\n' \
  "${routine_verification_exit}"
test "${routine_verification_exit}" -eq 0
```

Result `0` means that both prerequisites, the exact-role check and zero-change
plan all passed. Result `2` means the plan found drift or configuration change.
Result `1` can mean a failed prerequisite, identity mismatch or Terraform
error. Keep the backend, cache and private inputs intact on any non-zero result.
Do not apply a reported difference from this verification procedure.

## Scope of a zero-change result

A zero-change plan confirms that the source, private inputs, authoritative S3
state and refreshed Terraform-managed resources agree under the administration
role. `terraform state list` identifies the resource addresses covered by that
result.

It does not verify controls managed out of band, including:

- root MFA and root access-key posture;
- bootstrap-user MFA, access-key and policy hygiene;
- live versions of the root-created permissions boundaries;
- removal of the temporary bootstrap policy;
- GitHub Environment protection and configuration;
- successful GitHub OIDC federation.

Use the explicit checks in the account bootstrap runbook for those controls.

## Clear the shell environment

When verification and any local evidence recording are complete:

```zsh
unset aws_account_id aws_region state_bucket_name
unset compatibility_exit routine_init_exit routine_state_list_exit
unset routine_verification_exit
unset AWS_PROFILE AWS_DEFAULT_PROFILE
unset AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
unset AWS_LOGIN_CACHE_DIRECTORY AWS_EC2_METADATA_DISABLED
unset AWS_IGNORE_CONFIGURED_ENDPOINT_URLS
```

Do not delete the repository-local AWS configuration, login cache, backend
declaration, backend cache or private Terraform inputs as part of shell cleanup.

## References

- [Terraform plan](https://developer.hashicorp.com/terraform/cli/commands/plan)
- [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)
- [Terraform backend initialisation](https://developer.hashicorp.com/terraform/cli/commands/init)
- [AWS CLI sign-in with `aws login`](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
