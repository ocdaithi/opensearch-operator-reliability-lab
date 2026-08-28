#!/usr/bin/env bash

set -euo pipefail

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

if (($# != 0)); then
  fail "This command does not accept arguments."
fi

for command_name in git grep; do
  command -v "${command_name}" >/dev/null 2>&1 ||
    fail "Required command is unavailable: ${command_name}"
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
cd "${repository_root}"

validation_workflow=".github/workflows/terraform-validate.yml"
oidc_workflow=".github/workflows/verify-aws-oidc.yml"
bootstrap_runbook="docs/aws/account-bootstrap.md"
verification_runbook="docs/aws/verify-state.md"
security_document="docs/aws/bootstrap-security.md"
recovery_runbook="docs/aws/account-bootstrap-recovery.md"
bootstrap_article="docs/articles/aws-account-bootstrap-with-terraform.md"

required_documents=(
  README.md
  "${bootstrap_runbook}"
  "${verification_runbook}"
  "${security_document}"
  "${recovery_runbook}"
  "${bootstrap_article}"
)

for required_document in "${required_documents[@]}"; do
  [[ -f "${required_document}" && ! -L "${required_document}" ]] ||
    fail "Required documentation is not a regular file: ${required_document}"
done

for required_workflow in "${validation_workflow}" "${oidc_workflow}"; do
  git ls-files --error-unmatch -- "${required_workflow}" >/dev/null 2>&1 ||
    fail "Required workflow is not tracked: ${required_workflow}"
  [[ -f "${required_workflow}" && ! -L "${required_workflow}" ]] ||
    fail "Required workflow is not a tracked regular file: ${required_workflow}"
done

tracked_file_count=0
while IFS= read -r -d '' tracked_file; do
  tracked_file_count=$((tracked_file_count + 1))

  case "${tracked_file}" in
    .kube/* | */.kube/* | kubeconfig | */kubeconfig | \
      kubeconfig.* | */kubeconfig.* | *.kubeconfig)
      fail "A kubeconfig is tracked: ${tracked_file}"
      ;;
    .private/* | */.private/* | .aws/* | */.aws/* | \
      .terraform/* | */.terraform/* | backend.tf | */backend.tf | \
      *.tfvars | *.tfvars.json | temporary-bootstrap-policy.json | \
      */temporary-bootstrap-policy.json)
      fail "A private or generated Terraform file is tracked: ${tracked_file}"
      ;;
    *.tfstate | *.tfstate.* | *.tfplan | tfplan | */tfplan)
      fail "A Terraform state or plan artefact is tracked: ${tracked_file}"
      ;;
  esac
done < <(git ls-files -z)

content_pathspecs=(
  .
  ':(exclude)infra/bootstrap/tests/check-tracked-repository.sh'
  ':(exclude)infra/bootstrap/tests/test-tracked-repository.sh'
)

if git grep -I -q -E -e 'arn:aws:iam::[[:digit:]]{12}:' -- \
  "${content_pathspecs[@]}"; then
  fail "A tracked file contains an account-specific IAM ARN."
fi

if git grep -I -q -E \
  -e '(^|[^[:digit:]])[[:digit:]]{12}([^[:digit:]]|$)' -- \
  "${content_pathspecs[@]}"; then
  fail "A tracked file contains a possible AWS account ID."
fi

if git grep -I -q -E -e '(AKIA|ASIA)[A-Z0-9]{16}' -- \
  "${content_pathspecs[@]}"; then
  fail "A tracked file contains an AWS access-key identifier."
fi

if git grep -I -q -E \
  -e '(^|[^[:alnum:]_])(AWS_SECRET_ACCESS_KEY|aws_secret_access_key)[[:space:]]*[:=]' -- \
  "${content_pathspecs[@]}"; then
  fail "A tracked file contains a secret-access-key assignment."
fi

if git grep -I -q -E \
  -e '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' -- \
  "${content_pathspecs[@]}"; then
  fail "A tracked file contains a private key."
fi

workflow_files=()
while IFS= read -r workflow_file; do
  [[ -n "${workflow_file}" ]] && workflow_files+=("${workflow_file}")
done < <(git ls-files -- '.github/workflows/*.yml' '.github/workflows/*.yaml')

((${#workflow_files[@]} > 0)) || fail "No tracked GitHub Actions workflows were found."

for workflow_file in "${workflow_files[@]}"; do
  [[ -f "${workflow_file}" && ! -L "${workflow_file}" ]] ||
    fail "A tracked workflow is not a regular file: ${workflow_file}"

  workflow_content="$(<"${workflow_file}")"
  top_permissions_count="$(grep -Ec '^permissions:$' "${workflow_file}" || true)"
  top_permission_entries="$(
    grep -Ec '^  [[:alnum:]_-]+:[[:space:]]+(read|write|none)$' \
      "${workflow_file}" || true
  )"

  [[ "${top_permissions_count}" == "1" && \
    "${top_permission_entries}" == "1" ]] ||
    fail "Workflow must declare one minimal top-level permissions block: ${workflow_file}"

  case "${workflow_file}" in
    "${validation_workflow}")
      [[ "${workflow_content}" == *$'permissions:\n  contents: read'* ]] ||
        fail "Validation workflow must keep contents: read."
      ;;
    "${oidc_workflow}")
      [[ "${workflow_content}" == *$'permissions:\n  contents: none'* ]] ||
        fail "OIDC workflow must keep contents: none."
      ;;
    *)
      if [[ "${workflow_content}" != *$'permissions:\n  contents: read'* && \
        "${workflow_content}" != *$'permissions:\n  contents: none'* ]]; then
        fail "Workflow must use contents: read or contents: none: ${workflow_file}"
      fi
      ;;
  esac

  job_permissions_count="$(
    grep -Ec '^[[:space:]]+permissions:' "${workflow_file}" || true
  )"
  id_token_count="$(grep -Fc 'id-token: write' "${workflow_file}" || true)"

  if [[ "${workflow_file}" == "${oidc_workflow}" ]]; then
    [[ "${job_permissions_count}" == "1" && "${id_token_count}" == "1" ]] ||
      fail "OIDC workflow must grant id-token: write exactly once."
    grep -Fqx '      id-token: write' "${workflow_file}" ||
      fail "OIDC workflow must grant only its verification job an ID token."
  elif [[ "${job_permissions_count}" != "0" ]]; then
    fail "Unexpected job-level permissions block: ${workflow_file}"
  elif [[ "${id_token_count}" != "0" ]]; then
    fail "ID-token permission is only allowed in the OIDC workflow."
  fi
done

immutable_action_pattern='^[[:space:]]+uses:[[:space:]]+[^[:space:]@]+/[^[:space:]@]+@[0-9a-f]{40}([[:space:]]+#[[:space:]]*.*)?$'
action_reference_count=0
while IFS= read -r action_line; do
  action_reference_count=$((action_reference_count + 1))
  [[ "${action_line}" =~ ${immutable_action_pattern} ]] ||
    fail "GitHub Action reference is not pinned to an immutable commit: ${action_line}"
done < <(grep -hE '^[[:space:]]+uses:' "${workflow_files[@]}" || true)

deleted_bootstrap_scripts=(
  infra/bootstrap/scripts/check-backend-contract.sh
  infra/bootstrap/scripts/migrate-state.sh
  infra/bootstrap/scripts/policy-contract-digest.sh
  infra/bootstrap/scripts/render-s3-backend.sh
  infra/bootstrap/scripts/test-backend-contract.sh
  infra/bootstrap/scripts/test-migrate-state.sh
  infra/bootstrap/scripts/test-render-s3-backend.sh
  infra/bootstrap/scripts/test-verify-bootstrap-access.sh
  infra/bootstrap/scripts/verify-bootstrap-access.sh
)

for deleted_script in "${deleted_bootstrap_scripts[@]}"; do
  [[ ! -e "${deleted_script}" && ! -L "${deleted_script}" ]] ||
    fail "Deleted bootstrap script has been restored: ${deleted_script}"

  deleted_name="${deleted_script##*/}"
  if git grep -I -q -F -e "${deleted_name}" -- "${content_pathspecs[@]}"; then
    fail "Deleted bootstrap script is still referenced: ${deleted_name}"
  fi
done

prohibited_commands=(
  'terraform state push'
  'terraform state pull'
  'terraform state mv'
  'terraform state rm'
  'terraform init -force-copy'
  'aws s3 cp'
  'aws s3api put-object'
)

for prohibited_command in "${prohibited_commands[@]}"; do
  if git grep -I -q -F -e "${prohibited_command}" -- \
    "${content_pathspecs[@]}"; then
    fail "Tracked content contains a prohibited custom state command: ${prohibited_command}"
  fi
done

credential_clear_block=$'unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN\nunset AWS_SECURITY_TOKEN AWS_CREDENTIAL_EXPIRATION\nunset AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME\nunset AWS_CONTAINER_CREDENTIALS_RELATIVE_URI\nunset AWS_CONTAINER_CREDENTIALS_FULL_URI\nunset AWS_CONTAINER_AUTHORIZATION_TOKEN\nunset AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE\nunset AWS_ENDPOINT_URL AWS_ENDPOINT_URL_STS AWS_ENDPOINT_URL_S3\nunset AWS_ENDPOINT_URL_IAM AWS_ENDPOINT_URL_BUDGETS\nunset AWS_S3_ENDPOINT AWS_STS_ENDPOINT AWS_IAM_ENDPOINT\nunset AWS_BUDGETS_ENDPOINT\nunset AWS_PROFILE AWS_DEFAULT_PROFILE\nunset TF_CLI_ARGS TF_CLI_ARGS_init TF_CLI_ARGS_plan\nunset TF_CLI_ARGS_apply TF_CLI_ARGS_state TF_CLI_ARGS_show\nunset TF_CLI_ARGS_output TF_DATA_DIR TF_WORKSPACE\nunset TF_VAR_terraform_admin_role_arn'

for runbook in "${bootstrap_runbook}" "${verification_runbook}"; do
  runbook_content="$(<"${runbook}")"
  [[ "${runbook_content}" == *"${credential_clear_block}"* ]] ||
    fail "Credential clearing is incomplete in ${runbook}."
done

bootstrap_identity_block=$'    .Account == $account and\n    .Arn == ("arn:aws:iam::" + $account +\n      ":user/opensearch-lab-bootstrap")'
admin_identity_block=$'    .Account == $account and\n    (.Arn | test("^arn:aws:sts::" + $account +\n      ":assumed-role/opensearch-lab-terraform-admin/[^/]+$"))'
bootstrap_content="$(<"${bootstrap_runbook}")"
verification_content="$(<"${verification_runbook}")"

[[ "${bootstrap_content}" == *"${bootstrap_identity_block}"* ]] ||
  fail "Exact bootstrap-user identity check is missing from the bootstrap runbook."
[[ "${bootstrap_content}" == *"${admin_identity_block}"* ]] ||
  fail "Exact administration-role identity check is missing from the bootstrap runbook."
[[ "${verification_content}" == *"${admin_identity_block}"* ]] ||
  fail "Exact administration-role identity check is missing from the verification runbook."

migration_command="terraform -chdir=\"\${module_dir}\" init -migrate-state"
reconfiguration_command="terraform -chdir=\"\${module_dir}\" init -reconfigure"

[[ "${bootstrap_content}" == *"${migration_command}"* ]] ||
  fail "Fresh-account native state migration is not documented."
[[ "${bootstrap_content}" == *"${reconfiguration_command}"* ]] ||
  fail "Existing-account backend reconfiguration is not documented."
[[ "${bootstrap_content}" == *'The existing installation is already S3-backed. It must never run the fresh'* ]] ||
  fail "Fresh migration and existing-account reconfiguration are not clearly separated."

require_link() {
  local source_file="$1"
  local link_target="$2"

  grep -Fq -- "(${link_target})" "${source_file}" ||
    fail "Required local documentation link is missing: ${source_file} -> ${link_target}"
}

require_link README.md docs/aws/account-bootstrap.md
require_link README.md docs/aws/verify-state.md
require_link README.md docs/aws/bootstrap-security.md
require_link README.md docs/aws/account-bootstrap-recovery.md
require_link README.md docs/articles/aws-account-bootstrap-with-terraform.md
require_link "${bootstrap_runbook}" verify-state.md
require_link "${bootstrap_runbook}" account-bootstrap-recovery.md
require_link "${bootstrap_runbook}" bootstrap-security.md
require_link "${verification_runbook}" account-bootstrap.md
require_link "${recovery_runbook}" account-bootstrap.md
require_link "${security_document}" account-bootstrap.md
require_link "${security_document}" account-bootstrap-recovery.md

printf 'Tracked repository safeguards passed: %d files, %d pinned actions.\n' \
  "${tracked_file_count}" "${action_reference_count}"
