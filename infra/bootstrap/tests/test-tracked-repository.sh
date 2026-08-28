#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
negative_case_count=0

for command_name in git grep mktemp perl; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    printf 'Required command is unavailable: %s\n' "${command_name}" >&2
    exit 1
  fi
done

make_fixture() {
  local fixture_name="$1"
  local fixture_root="${test_root}/${fixture_name}"

  mkdir -p \
    "${fixture_root}/.github/workflows" \
    "${fixture_root}/docs/articles" \
    "${fixture_root}/docs/aws" \
    "${fixture_root}/infra/bootstrap/tests"
  git -C "${fixture_root}" init -q
  cp "${source_root}/.gitignore" "${fixture_root}/.gitignore"
  cp "${source_root}/README.md" "${fixture_root}/README.md"
  cp "${source_root}/.github/workflows/terraform-validate.yml" \
    "${fixture_root}/.github/workflows/terraform-validate.yml"
  cp "${source_root}/.github/workflows/verify-aws-oidc.yml" \
    "${fixture_root}/.github/workflows/verify-aws-oidc.yml"
  cp "${source_root}/docs/aws/account-bootstrap.md" \
    "${fixture_root}/docs/aws/account-bootstrap.md"
  cp "${source_root}/docs/aws/verify-state.md" \
    "${fixture_root}/docs/aws/verify-state.md"
  cp "${source_root}/docs/aws/bootstrap-security.md" \
    "${fixture_root}/docs/aws/bootstrap-security.md"
  cp "${source_root}/docs/aws/account-bootstrap-recovery.md" \
    "${fixture_root}/docs/aws/account-bootstrap-recovery.md"
  cp "${source_root}/docs/articles/aws-account-bootstrap-with-terraform.md" \
    "${fixture_root}/docs/articles/aws-account-bootstrap-with-terraform.md"
  cp "${source_root}/infra/bootstrap/tests/check-tracked-repository.sh" \
    "${fixture_root}/infra/bootstrap/tests/check-tracked-repository.sh"
  git -C "${fixture_root}" add .
  printf '%s\n' "${fixture_root}"
}

expect_failure() {
  local case_name="$1"
  local expected_error="$2"
  local fixture_root="${test_root}/${case_name}"
  local output_file="${fixture_root}/check.log"

  if "${fixture_root}/infra/bootstrap/tests/check-tracked-repository.sh" \
    >"${output_file}" 2>&1; then
    printf 'Tracked repository safeguard unexpectedly accepted: %s\n' \
      "${case_name}" >&2
    exit 1
  fi
  if ! grep -Fq -- "${expected_error}" "${output_file}"; then
    printf 'Tracked repository safeguard failed unexpectedly: %s\n' \
      "${case_name}" >&2
    tail -20 "${output_file}" >&2
    exit 1
  fi

  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: %s\n' "${case_name}"
}

baseline_fixture="$(make_fixture baseline)"
"${baseline_fixture}/infra/bootstrap/tests/check-tracked-repository.sh" >/dev/null
printf 'positive case: baseline\n'

static_credential_fixture="$(make_fixture retained-static-credential)"
perl -0pi -e '
  s/AWS_ACCESS_KEY_ID/AWS_ACCESS_KEY_REMOVED/
    or die "Static-credential mutation was not applied.\n"
' "${static_credential_fixture}/docs/aws/account-bootstrap.md"
git -C "${static_credential_fixture}" add .
expect_failure "retained-static-credential" "Credential clearing is incomplete"

admin_identity_fixture="$(make_fixture broadened-admin-identity)"
perl -0pi -e '
  s/opensearch-lab-terraform-admin\/\[\^\/\]\+\$/opensearch-lab-.*-admin\/[^\/]+\$/g
    or die "Administration-role identity mutation was not applied.\n"
' "${admin_identity_fixture}/docs/aws/account-bootstrap.md"
git -C "${admin_identity_fixture}" add .
expect_failure \
  "broadened-admin-identity" \
  "Exact administration-role identity check is missing"

unpinned_fixture="$(make_fixture unpinned-action)"
perl -0pi -e '
  s#actions/checkout@[0-9a-f]{40}#actions/checkout\@v4#
    or die "Action-pin mutation was not applied.\n"
' "${unpinned_fixture}/.github/workflows/terraform-validate.yml"
git -C "${unpinned_fixture}" add .
expect_failure "unpinned-action" "not pinned to an immutable commit"

oidc_second_token_fixture="$(make_fixture oidc-second-token-job)"
perl -0pi -e '
  s/    timeout-minutes: 1/    permissions:\n      id-token: write\n    timeout-minutes: 1/
    or die "Second-token mutation was not applied.\n"
' "${oidc_second_token_fixture}/.github/workflows/verify-aws-oidc.yml"
git -C "${oidc_second_token_fixture}" add .
expect_failure \
  "oidc-second-token-job" \
  "OIDC workflow must grant id-token: write exactly once"

oidc_permission_fixture="$(make_fixture oidc-repository-permission)"
perl -0pi -e '
  s/  contents: none/  contents: read/
    or die "OIDC repository-permission mutation was not applied.\n"
' "${oidc_permission_fixture}/.github/workflows/verify-aws-oidc.yml"
git -C "${oidc_permission_fixture}" add .
expect_failure \
  "oidc-repository-permission" \
  "OIDC workflow must keep contents: none"

write_permission_fixture="$(make_fixture workflow-write-permission)"
perl -0pi -e '
  s/  contents: read/  contents: write/
    or die "Workflow write-permission mutation was not applied.\n"
' "${write_permission_fixture}/.github/workflows/terraform-validate.yml"
git -C "${write_permission_fixture}" add .
expect_failure \
  "workflow-write-permission" \
  "Validation workflow must keep contents: read"

job_permission_fixture="$(make_fixture job-write-all-permission)"
perl -0pi -e '
  s/(    runs-on: ubuntu-24\.04\n)/$1    permissions: write-all\n/
    or die "Job-level permission mutation was not applied.\n"
' "${job_permission_fixture}/.github/workflows/terraform-validate.yml"
git -C "${job_permission_fixture}" add .
expect_failure \
  "job-write-all-permission" \
  "Unexpected job-level permissions block"

missing_permissions_fixture="$(make_fixture missing-workflow-permissions)"
printf '%s\n' \
  'name: Unreviewed workflow' \
  '' \
  'on:' \
  '  workflow_dispatch:' \
  '' \
  'jobs:' \
  '  test:' \
  '    runs-on: ubuntu-24.04' \
  '    steps:' \
  '      - run: true' \
  >"${missing_permissions_fixture}/.github/workflows/unreviewed.yml"
git -C "${missing_permissions_fixture}" add .
expect_failure \
  "missing-workflow-permissions" \
  "Workflow must declare one minimal top-level permissions block"

symlinked_workflow_fixture="$(make_fixture symlinked-workflow)"
mkdir -p "${symlinked_workflow_fixture}/.private"
cp "${symlinked_workflow_fixture}/.github/workflows/terraform-validate.yml" \
  "${symlinked_workflow_fixture}/.private/terraform-validate.yml"
rm -- "${symlinked_workflow_fixture}/.github/workflows/terraform-validate.yml"
ln -s ../../.private/terraform-validate.yml \
  "${symlinked_workflow_fixture}/.github/workflows/terraform-validate.yml"
git -C "${symlinked_workflow_fixture}" add \
  .github/workflows/terraform-validate.yml
expect_failure \
  "symlinked-workflow" \
  "Required workflow is not a tracked regular file"

account_id="$(printf '%s%s%s' 1234 5678 9012)"
account_fixture="$(make_fixture account-specific-iam-arn)"
printf 'arn:aws:iam::%s:role/synthetic\n' "${account_id}" \
  >"${account_fixture}/account.txt"
git -C "${account_fixture}" add .
expect_failure "account-specific-iam-arn" "account-specific IAM ARN"

bare_account_fixture="$(make_fixture bare-account-id)"
printf '%s\n' "${account_id}" >"${bare_account_fixture}/account.txt"
git -C "${bare_account_fixture}" add .
expect_failure "bare-account-id" "possible AWS account ID"

access_key_fixture="$(make_fixture aws-access-key)"
access_key_prefix="$(printf '%s%s' AK IA)"
access_key_suffix="$(printf '%s%s' ABCDEFGH IJKLMNOP)"
printf 'credential=%s%s\n' "${access_key_prefix}" "${access_key_suffix}" \
  >"${access_key_fixture}/credential.txt"
git -C "${access_key_fixture}" add .
expect_failure "aws-access-key" "AWS access-key identifier"

secret_fixture="$(make_fixture aws-secret-access-key)"
secret_variable="$(printf '%s%s' AWS_SECRET_ ACCESS_KEY)"
secret_value="$(printf '%s%s%s%s' abcdefghij klmnopqrst uvwxyzABCD EFGHIJKLMN)"
printf '%s=%s\n' "${secret_variable}" "${secret_value}" \
  >"${secret_fixture}/secret.txt"
git -C "${secret_fixture}" add .
expect_failure "aws-secret-access-key" "secret-access-key assignment"

private_key_fixture="$(make_fixture private-key-generic)"
private_key_label="$(printf '%s%s' PRIVATE ' KEY')"
printf '%s\n' "-----BEGIN ${private_key_label}-----" \
  >"${private_key_fixture}/private-key.txt"
git -C "${private_key_fixture}" add .
expect_failure "private-key-generic" "contains a private key"

state_fixture="$(make_fixture tracked-state)"
printf '{}\n' >"${state_fixture}/infra/bootstrap/leak.tfstate"
git -C "${state_fixture}" add -f infra/bootstrap/leak.tfstate
expect_failure "tracked-state" "state or plan artefact is tracked"

kubeconfig_fixture="$(make_fixture tracked-kubeconfig)"
printf '%s\n' 'apiVersion: v1' >"${kubeconfig_fixture}/kubeconfig"
git -C "${kubeconfig_fixture}" add -f kubeconfig
expect_failure "tracked-kubeconfig" "A kubeconfig is tracked"

private_fixture="$(make_fixture tracked-private-file)"
mkdir -p "${private_fixture}/.private"
printf 'private\n' >"${private_fixture}/.private/record.txt"
git -C "${private_fixture}" add -f .private/record.txt
expect_failure "tracked-private-file" "private or generated Terraform file is tracked"

alternate_backend_fixture="$(make_fixture tracked-alternate-backend)"
mkdir -p "${alternate_backend_fixture}/components/example"
printf '%s\n' 'terraform { backend "local" {} }' \
  >"${alternate_backend_fixture}/components/example/backend.tf"
git -C "${alternate_backend_fixture}" add .
expect_failure \
  "tracked-alternate-backend" \
  "private or generated Terraform file is tracked"

printf 'Tracked repository mutation safeguards passed (%d negative cases).\n' \
  "${negative_case_count}"
