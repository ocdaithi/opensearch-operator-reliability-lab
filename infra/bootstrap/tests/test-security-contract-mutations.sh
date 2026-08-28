#!/usr/bin/env bash

set -euo pipefail

bootstrap_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_bin="${TERRAFORM_BIN:-terraform}"
terraform_data_dir="${TF_DATA_DIR:-}"
negative_case_count=0

if [[ -z "${terraform_data_dir}" || "${terraform_data_dir}" != /* ]]; then
  printf 'Set TF_DATA_DIR to an absolute, isolated Terraform data directory.\n' >&2
  exit 1
fi

if ! compgen -G "${terraform_data_dir}/providers/registry.terraform.io/hashicorp/aws/6.61.0/*/terraform-provider-aws_*" >/dev/null; then
  printf 'Run terraform init -backend=false with the isolated TF_DATA_DIR before the mutation tests.\n' >&2
  exit 1
fi

mutation_root="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-security-mutations.XXXXXX")"
trap 'rm -rf -- "${mutation_root}"' EXIT

record_case() {
  negative_case_count=$((negative_case_count + 1))
  printf 'PASS negative case: %s\n' "$1"
}

assert_mutated_hcl_parses() {
  local case_name="$1"
  local fixture_dir="$2"

  if ! "${terraform_bin}" fmt -write=false -recursive "${fixture_dir}" \
    >/dev/null 2>&1; then
    printf 'FAIL %s: unrelated HCL parsing failure masked the mutation.\n' \
      "${case_name}" >&2
    exit 1
  fi
}

copy_terraform_fixture() {
  local fixture_dir="$1"
  local source_file

  mkdir -p "${fixture_dir}/tests"
  for source_file in "${bootstrap_dir}"/*.tf; do
    if [[ "$(basename "${source_file}")" != "backend.tf" ]]; then
      cp "${source_file}" "${fixture_dir}/"
    fi
  done

  cp "${bootstrap_dir}/.terraform.lock.hcl" "${fixture_dir}/"
  cp "${bootstrap_dir}/tests/security_contracts.tftest.hcl" "${fixture_dir}/tests/"
}

apply_terraform_mutation() {
  local case_name="$1"
  local fixture_dir="$2"
  local mutated_file="${fixture_dir}/mutation.tmp"
  local synthetic_account_id
  local synthetic_topic_arn

  case "${case_name}" in
    wildcard-oidc-subject-with-ignore-changes)
      perl -0pi -e 's#github_subject\s+= "[^"]+"#github_subject = "repo:*"#' "${fixture_dir}/locals.tf"
      perl -0pi -e 's/(resource "aws_iam_role" "github_actions" \{.*?max_session_duration = 3600\n)/$1\n  lifecycle {\n    ignore_changes = [assume_role_policy]\n  }\n/s' \
        "${fixture_dir}/github-oidc.tf"
      grep -Fq 'github_subject = "repo:*"' "${fixture_dir}/locals.tf"
      grep -Fq 'ignore_changes = [assume_role_policy]' "${fixture_dir}/github-oidc.tf"
      ;;
    name-only-oidc-subject)
      perl -0pi -e 's#github_subject\s+= "[^"]+"#github_subject = "repo:example-owner/example-repository:environment:aws-bootstrap"#' \
        "${fixture_dir}/locals.tf"
      perl -0pi -e 's/(resource "aws_iam_role" "github_actions" \{.*?max_session_duration = 3600\n)/$1\n  lifecycle {\n    ignore_changes = [assume_role_policy]\n  }\n/s' \
        "${fixture_dir}/github-oidc.tf"
      grep -Fq 'github_subject = "repo:example-owner/example-repository:environment:aws-bootstrap"' \
        "${fixture_dir}/locals.tf"
      grep -Fq 'ignore_changes = [assume_role_policy]' "${fixture_dir}/github-oidc.tf"
      ;;
    broadened-human-trust-with-ignore-changes)
      perl -0pi -e 's/identifiers = \[data\.aws_iam_user\.bootstrap\.arn\]/identifiers = ["*"]/' \
        "${fixture_dir}/human-access.tf"
      perl -0pi -e 's/(resource "aws_iam_role" "terraform_admin" \{.*?max_session_duration = 3600\n)/$1\n  lifecycle {\n    ignore_changes = [assume_role_policy]\n  }\n/s' \
        "${fixture_dir}/human-access.tf"
      grep -Fq 'identifiers = ["*"]' "${fixture_dir}/human-access.tf"
      grep -Fq 'ignore_changes = [assume_role_policy]' "${fixture_dir}/human-access.tf"
      ;;
    extra-oidc-audience)
      perl -0pi -e 's/client_id_list = \["sts\.amazonaws\.com"\]/client_id_list = ["sts.amazonaws.com", "example.invalid"]/' "${fixture_dir}/github-oidc.tf"
      grep -Fq 'client_id_list = ["sts.amazonaws.com", "example.invalid"]' "${fixture_dir}/github-oidc.tf"
      ;;
    delete-state-object)
      perl -0pi -e 's/(sid\s+= "ReadAndWriteTerraformState".*?actions = \[\n\s+"s3:GetObject",\n)/$1      "s3:DeleteObject",\n/s' "${fixture_dir}/backend-access.tf"
      grep -A8 -F 'sid    = "ReadAndWriteTerraformState"' \
        "${fixture_dir}/backend-access.tf" | grep -Fq '"s3:DeleteObject"'
      ;;
    extra-terraform-admin-action)
      perl -0pi -e 's/(sid\s+= "ManageStateBucketControls".*?actions = \[\n)/$1      "s3:DeleteBucket",\n/s' "${fixture_dir}/human-access.tf"
      grep -A6 -F 'sid    = "ManageStateBucketControls"' \
        "${fixture_dir}/human-access.tf" | grep -Fq '"s3:DeleteBucket"'
      ;;
    reintroduced-admin-bucket-policy)
      perl -0pi -e 's/      "s3:GetBucketPolicy",/      "s3:GetBucketPolicy",\n      "s3:PutBucketPolicy",/' \
        "${fixture_dir}/human-access.tf"
      grep -A3 -F '"s3:GetBucketPolicy"' \
        "${fixture_dir}/human-access.tf" | grep -Fq '"s3:PutBucketPolicy"'
      ;;
    extra-github-permission)
      perl -0pi -e 's/(sid\s+= "ReadAndWriteTerraformState".*?actions = \[\n)/$1      "s3:GetObjectVersion",\n/s' "${fixture_dir}/backend-access.tf"
      grep -A6 -F 'sid    = "ReadAndWriteTerraformState"' \
        "${fixture_dir}/backend-access.tf" | grep -Fq '"s3:GetObjectVersion"'
      ;;
    budget-sns-subscriber)
      synthetic_account_id="$(printf '%s%s%s' 0000 0000 0000)"
      synthetic_topic_arn="arn:aws:sns:eu-west-1:${synthetic_account_id}:unsafe"
      awk -v topic_arn="${synthetic_topic_arn}" '
        { print }
        !inserted && /subscriber_email_addresses/ {
          print "      subscriber_sns_topic_arns = [\"" topic_arn "\"]"
          inserted = 1
        }
      ' "${fixture_dir}/budget.tf" >"${mutated_file}"
      mv "${mutated_file}" "${fixture_dir}/budget.tf"
      grep -Fq 'subscriber_sns_topic_arns' "${fixture_dir}/budget.tf"
      ;;
    weakened-bucket-ownership)
      perl -0pi -e 's/object_ownership = "BucketOwnerEnforced"/object_ownership = "ObjectWriter"/' \
        "${fixture_dir}/state.tf"
      grep -Fq 'object_ownership = "ObjectWriter"' "${fixture_dir}/state.tf"
      ;;
    wrong-budget-name)
      perl -0pi -e 's/budget_name\s+= "[^"]+"/budget_name                   = "unsafe-budget-name"/' \
        "${fixture_dir}/locals.tf"
      grep -Fq 'budget_name                   = "unsafe-budget-name"' \
        "${fixture_dir}/locals.tf"
      ;;
    billing-view-wildcard)
      perl -0pi -e 's#primary_billing_view_arn\s+= "[^"]+"#primary_billing_view_arn     = "*"#' \
        "${fixture_dir}/locals.tf"
      grep -Fq 'primary_billing_view_arn     = "*"' "${fixture_dir}/locals.tf"
      ;;
    billing-view-prefix-wildcard)
      perl -0pi -e 's#primary_billing_view_arn\s+= "[^"]+"#primary_billing_view_arn     = "arn:aws:billing::\${join("", ["0000", "0000", "0000"])}:billingview/*"#' \
        "${fixture_dir}/locals.tf"
      grep -Fq 'primary_billing_view_arn     = "arn:aws:billing::' "${fixture_dir}/locals.tf"
      grep -Fq '["0000", "0000", "0000"])}:billingview/*"' "${fixture_dir}/locals.tf"
      ;;
    billing-view-wrong-account)
      perl -0pi -e 's#primary_billing_view_arn\s+= "[^"]+"#primary_billing_view_arn     = "arn:aws:billing::\${join("", ["0000", "0000", "0001"])}:billingview/primary"#' \
        "${fixture_dir}/locals.tf"
      grep -Fq 'primary_billing_view_arn     = "arn:aws:billing::' "${fixture_dir}/locals.tf"
      grep -Fq '["0000", "0000", "0001"])}:billingview/primary"' "${fixture_dir}/locals.tf"
      ;;
    billing-view-wrong-partition)
      perl -0pi -e 's#primary_billing_view_arn\s+= "[^"]+"#primary_billing_view_arn     = "arn:aws-cn:billing::\${join("", ["0000", "0000", "0000"])}:billingview/primary"#' \
        "${fixture_dir}/locals.tf"
      grep -Fq 'primary_billing_view_arn     = "arn:aws-cn:billing::' "${fixture_dir}/locals.tf"
      grep -Fq '["0000", "0000", "0000"])}:billingview/primary"' "${fixture_dir}/locals.tf"
      ;;
    billing-view-custom-arn)
      perl -0pi -e 's#primary_billing_view_arn\s+= "[^"]+"#primary_billing_view_arn     = "arn:aws:billing::\${join("", ["0000", "0000", "0000"])}:billingview/custom"#' \
        "${fixture_dir}/locals.tf"
      grep -Fq 'primary_billing_view_arn     = "arn:aws:billing::' "${fixture_dir}/locals.tf"
      grep -Fq '["0000", "0000", "0000"])}:billingview/custom"' "${fixture_dir}/locals.tf"
      ;;
    commercial-partition-broadening)
      perl -0pi -e 's/data\.aws_partition\.current\.partition == "aws"/contains(["aws", "aws-cn"], data.aws_partition.current.partition)/' \
        "${fixture_dir}/state.tf"
      grep -Fq 'contains(["aws", "aws-cn"], data.aws_partition.current.partition)' \
        "${fixture_dir}/state.tf"
      ;;
    *)
      printf 'Unknown Terraform mutation case: %s\n' "${case_name}" >&2
      exit 1
      ;;
  esac
}

run_terraform_negative() {
  local case_name="$1"
  local expected_error="$2"
  local allowed_error_header="${3:-Error: Test assertion failed}"
  local fixture_dir="${mutation_root}/${case_name}"
  local test_log="${mutation_root}/${case_name}.log"
  local test_status

  copy_terraform_fixture "${fixture_dir}"
  apply_terraform_mutation "${case_name}" "${fixture_dir}"

  set +e
  AWS_EC2_METADATA_DISABLED=true \
    AWS_ENDPOINT_URL=http://127.0.0.1:9 \
    TF_DATA_DIR="${terraform_data_dir}" \
    "${terraform_bin}" -chdir="${fixture_dir}" test -no-color >"${test_log}" 2>&1
  test_status=$?
  set -e

  if [[ ${test_status} -eq 0 ]]; then
    printf 'FAIL %s: unsafe mutation passed the contract suite.\n' "${case_name}" >&2
    exit 1
  fi
  if ! grep -Fq "${expected_error}" "${test_log}"; then
    printf 'FAIL %s: suite did not report the intended contract.\n' "${case_name}" >&2
    tail -40 "${test_log}" >&2
    exit 1
  fi
  if awk -v allowed_error_header="${allowed_error_header}" '
    /^Error:/ && $0 != allowed_error_header { unexpected = 1 }
    END { exit !unexpected }
  ' "${test_log}"; then
    printf 'FAIL %s: unrelated Terraform failure masked the mutation.\n' "${case_name}" >&2
    tail -40 "${test_log}" >&2
    exit 1
  fi

  record_case "${case_name}"
}

copy_policy_fixture() {
  local fixture_dir="$1"

  mkdir -p \
    "${fixture_dir}/infra/bootstrap/policies" \
    "${fixture_dir}/infra/bootstrap/scripts"
  cp "${bootstrap_dir}/policies/temporary-bootstrap-policy.template.json" \
    "${fixture_dir}/infra/bootstrap/policies/"
  cp "${bootstrap_dir}/policies/terraform-admin-boundary.template.json" \
    "${fixture_dir}/infra/bootstrap/policies/"
  cp "${bootstrap_dir}/policies/github-actions-boundary.template.json" \
    "${fixture_dir}/infra/bootstrap/policies/"
  cp "${bootstrap_dir}/scripts/generate-temporary-policy.sh" \
    "${fixture_dir}/infra/bootstrap/scripts/"
  cp "${bootstrap_dir}/scripts/generate-permissions-boundaries.sh" \
    "${fixture_dir}/infra/bootstrap/scripts/"
  cp "${bootstrap_dir}/scripts/test-generate-temporary-policy.sh" \
    "${fixture_dir}/infra/bootstrap/scripts/"
  cp "${bootstrap_dir}/scripts/test-generate-permissions-boundaries.sh" \
    "${fixture_dir}/infra/bootstrap/scripts/"
}

apply_policy_mutation() {
  local case_name="$1"
  local fixture_dir="$2"
  local temporary_template="${fixture_dir}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
  local human_boundary="${fixture_dir}/infra/bootstrap/policies/terraform-admin-boundary.template.json"
  local github_boundary="${fixture_dir}/infra/bootstrap/policies/github-actions-boundary.template.json"
  local generator="${fixture_dir}/infra/bootstrap/scripts/generate-temporary-policy.sh"
  local mutated_file="${fixture_dir}/mutated.json"

  case "${case_name}" in
    extra-temporary-action)
      jq '(.Statement[] | select(.Sid == "ReadExactBootstrapUser") | .Action) = ["iam:GetUser", "iam:GetUserPolicy"]' \
        "${temporary_template}" >"${mutated_file}"
      mv "${mutated_file}" "${temporary_template}"
      jq -e 'any(.Statement[]; .Sid == "ReadExactBootstrapUser" and (.Action | index("iam:GetUserPolicy") != null))' \
        "${temporary_template}" >/dev/null
      ;;
    extra-temporary-statement)
      jq '.Statement += [{
        "Sid": "UnexpectedDeny",
        "Effect": "Deny",
        "NotAction": "iam:GetUser",
        "NotResource": "arn:aws:iam::__AWS_ACCOUNT_ID__:user/opensearch-lab-bootstrap"
      }]' "${temporary_template}" >"${mutated_file}"
      mv "${mutated_file}" "${temporary_template}"
      jq -e 'any(.Statement[]; .Sid == "UnexpectedDeny")' \
        "${temporary_template}" >/dev/null
      ;;
    removed-temporary-expiry)
      jq 'del(.Statement[0].Condition.DateLessThan)' \
        "${temporary_template}" >"${mutated_file}"
      mv "${mutated_file}" "${temporary_template}"
      jq -e '.Statement[0].Condition | has("DateLessThan") | not' \
        "${temporary_template}" >/dev/null
      ;;
    broadened-temporary-resource)
      jq '(.Statement[] | select(.Sid == "ReadExactBootstrapUser") | .Resource) = "arn:aws:iam::__AWS_ACCOUNT_ID__:user/*"' \
        "${temporary_template}" >"${mutated_file}"
      mv "${mutated_file}" "${temporary_template}"
      jq -e 'any(.Statement[]; .Sid == "ReadExactBootstrapUser" and .Resource == "arn:aws:iam::__AWS_ACCOUNT_ID__:user/*")' \
        "${temporary_template}" >/dev/null
      ;;
    extra-github-boundary-action)
      jq '(.Statement[] | select(.Sid == "ReadAndWriteTerraformState") | .Action) += ["s3:GetObjectVersion"]' \
        "${github_boundary}" >"${mutated_file}"
      mv "${mutated_file}" "${github_boundary}"
      jq -e 'any(.Statement[]; .Sid == "ReadAndWriteTerraformState" and (.Action | index("s3:GetObjectVersion") != null))' \
        "${github_boundary}" >/dev/null
      ;;
    reintroduced-human-boundary-bucket-policy)
      jq '(.Statement[] | select(.Sid == "ManageStateBucketControls") | .Action) += ["s3:PutBucketPolicy"]' \
        "${human_boundary}" >"${mutated_file}"
      mv "${mutated_file}" "${human_boundary}"
      jq -e 'any(.Statement[]; .Sid == "ManageStateBucketControls" and (.Action | index("s3:PutBucketPolicy") != null))' \
        "${human_boundary}" >/dev/null
      ;;
    longer-temporary-expiry)
      perl -0pi -e 's/lifetime_seconds=14400/lifetime_seconds=28800/' "${generator}"
      grep -Fq 'lifetime_seconds=28800' "${generator}"
      ;;
    *)
      printf 'Unknown policy mutation case: %s\n' "${case_name}" >&2
      exit 1
      ;;
  esac
}

run_policy_negative() {
  local case_name="$1"
  local test_script="$2"
  local expected_error="$3"
  local fixture_dir="${mutation_root}/${case_name}"
  local test_log="${mutation_root}/${case_name}.log"
  local test_status

  copy_policy_fixture "${fixture_dir}"
  apply_policy_mutation "${case_name}" "${fixture_dir}"

  set +e
  "${fixture_dir}/infra/bootstrap/scripts/${test_script}" >"${test_log}" 2>&1
  test_status=$?
  set -e

  if [[ ${test_status} -eq 0 ]]; then
    printf 'FAIL %s: unsafe policy mutation passed its contract test.\n' "${case_name}" >&2
    exit 1
  fi
  if ! grep -Fq "${expected_error}" "${test_log}"; then
    printf 'FAIL %s: policy test did not report the intended contract.\n' "${case_name}" >&2
    tail -40 "${test_log}" >&2
    exit 1
  fi

  record_case "${case_name}"
}

copy_static_fixture() {
  local fixture_dir="$1"
  local source_file

  mkdir -p "${fixture_dir}/tests"
  for source_file in "${bootstrap_dir}"/*.tf; do
    if [[ "$(basename "${source_file}")" != "backend.tf" ]]; then
      cp "${source_file}" "${fixture_dir}/"
    fi
  done
  cp "${bootstrap_dir}/backend.s3.tf.example" "${fixture_dir}/"
  cp "${bootstrap_dir}/tests/inspect-hcl-structure.py" "${fixture_dir}/tests/"
  cp "${bootstrap_dir}/tests/test-static-security-contracts.sh" "${fixture_dir}/tests/"
}

run_structural_static_negative() {
  local case_name="$1"
  local expected_error="$2"
  local fixture_dir="${mutation_root}/${case_name}/infra/bootstrap"
  local test_log="${mutation_root}/${case_name}.log"

  copy_static_fixture "${fixture_dir}"
  case "${case_name}" in
    comment-separated-resource-header)
      printf '%s\n' \
        'resource /* reviewed parser mutation */ "aws_instance" /* label separator */ "unsafe_runtime" {' \
        '  ami           = "synthetic"' \
        '  instance_type = "synthetic"' \
        '}' >"${fixture_dir}/unsafe-commented-resource.tf"
      grep -Fq '/* label separator */ "unsafe_runtime" {' \
        "${fixture_dir}/unsafe-commented-resource.tf"
      ;;
    comment-separated-module-header)
      printf '%s\n' \
        'module /* reviewed parser mutation */ "unsafe_module" /* label separator */ {' \
        '  source = "./synthetic"' \
        '}' >"${fixture_dir}/unsafe-commented-module.tf"
      grep -Fq '/* reviewed parser mutation */ "unsafe_module"' \
        "${fixture_dir}/unsafe-commented-module.tf"
      ;;
    resource-provisioner)
      perl -0pi -e 's/(resource "aws_s3_bucket" "state" \{\n)/$1  provisioner "local-exec" {\n    command = "true"\n  }\n\n/' \
        "${fixture_dir}/state.tf"
      grep -Fq 'provisioner "local-exec"' "${fixture_dir}/state.tf"
      ;;
    lifecycle-ignore-changes)
      perl -0pi -e 's/(resource "aws_iam_role" "github_actions" \{.*?max_session_duration = 3600\n)/$1\n  lifecycle {\n    ignore_changes = [assume_role_policy]\n  }\n/s' \
        "${fixture_dir}/github-oidc.tf"
      grep -Fq 'ignore_changes = [assume_role_policy]' \
        "${fixture_dir}/github-oidc.tf"
      ;;
    future-budget-start)
      perl -0pi -e 's/(time_unit\s+= "MONTHLY"\n)/$1  time_period_start = "2099-01-01_00:00"\n/' \
        "${fixture_dir}/budget.tf"
      grep -Fq 'time_period_start = "2099-01-01_00:00"' \
        "${fixture_dir}/budget.tf"
      ;;
    provider-assume-role)
      perl -0pi -e 's#(provider "aws" \{\n)#$1  assume_role {\n    role_arn = "arn:aws:iam::0000:role/unsafe"\n  }\n\n#' \
        "${fixture_dir}/providers.tf"
      grep -Fq 'assume_role {' "${fixture_dir}/providers.tf"
      ;;
    provider-assume-role-with-web-identity)
      perl -0pi -e 's#(provider "aws" \{\n)#$1  assume_role_with_web_identity {\n    role_arn                = "arn:aws:iam::0000:role/unsafe"\n    web_identity_token_file = "/tmp/synthetic-token"\n  }\n\n#' \
        "${fixture_dir}/providers.tf"
      grep -Fq 'assume_role_with_web_identity {' "${fixture_dir}/providers.tf"
      ;;
    provider-profile)
      perl -0pi -e 's#(provider "aws" \{\n)#$1  profile = "unsafe-profile"\n#' \
        "${fixture_dir}/providers.tf"
      grep -Fq 'profile = "unsafe-profile"' "${fixture_dir}/providers.tf"
      ;;
    backend-example-profile)
      perl -0pi -e 's/backend "s3" \{\}/backend "s3" {\n    profile = "unsafe-profile"\n  }/' \
        "${fixture_dir}/backend.s3.tf.example"
      grep -Fq 'profile = "unsafe-profile"' \
        "${fixture_dir}/backend.s3.tf.example"
      ;;
    backend-example-role-assumption)
      perl -0pi -e 's#backend "s3" \{\}#backend "s3" {\n    assume_role = {\n      role_arn = "arn:aws:iam::0000:role/unsafe"\n    }\n  }#' \
        "${fixture_dir}/backend.s3.tf.example"
      grep -Fq 'assume_role = {' "${fixture_dir}/backend.s3.tf.example"
      ;;
    budget-email-default)
      perl -0pi -e 's/(variable "budget_notification_email" \{.*?sensitive\s+= true\n)/$1  default     = "alerts\@example.invalid"\n/s' \
        "${fixture_dir}/variables.tf"
      grep -Fq 'default     = "alerts@example.invalid"' \
        "${fixture_dir}/variables.tf"
      ;;
    budget-email-commented-default)
      perl -0pi -e 's/(variable "budget_notification_email" \{.*?sensitive\s+= true\n)/$1  default \/* reviewed *\/ = "alerts\@example.invalid"\n/s' \
        "${fixture_dir}/variables.tf"
      grep -Fq 'default /* reviewed */ = "alerts@example.invalid"' \
        "${fixture_dir}/variables.tf"
      ;;
    hard-coded-provider-region)
      perl -0pi -e 's/region\s+= var\.aws_region/region = "eu-west-1"/' \
        "${fixture_dir}/providers.tf"
      grep -Fq 'region = "eu-west-1"' "${fixture_dir}/providers.tf"
      ;;
    removed-account-allow-list)
      perl -0pi -e 's/^  allowed_account_ids = \[var\.expected_aws_account_id\]\n//m' \
        "${fixture_dir}/providers.tf"
      if grep -Fq 'allowed_account_ids' "${fixture_dir}/providers.tf"; then
        printf 'FAIL %s: the account allow-list mutation was not applied.\n' \
          "${case_name}" >&2
        exit 1
      fi
      ;;
    *)
      printf 'Unknown structural mutation case: %s\n' "${case_name}" >&2
      exit 1
      ;;
  esac

  assert_mutated_hcl_parses "${case_name}" "${fixture_dir}"

  if "${fixture_dir}/tests/test-static-security-contracts.sh" >"${test_log}" 2>&1; then
    printf 'FAIL %s: the static contract accepted the structural mutation.\n' \
      "${case_name}" >&2
    exit 1
  fi
  if ! grep -Fq "${expected_error}" "${test_log}"; then
    printf 'FAIL %s: static test did not report the intended contract.\n' \
      "${case_name}" >&2
    cat "${test_log}" >&2
    exit 1
  fi

  record_case "${case_name}"
}

run_boundary_assignment_negative() {
  local case_name="$1"
  local configuration_file="$2"
  local original_boundary="$3"
  local replacement_boundary="$4"
  local expected_error="$5"
  local fixture_dir="${mutation_root}/${case_name}/infra/bootstrap"
  local test_log="${mutation_root}/${case_name}.log"

  copy_static_fixture "${fixture_dir}"
  perl -0pi -e \
    "s/permissions_boundary = ${original_boundary}/permissions_boundary = ${replacement_boundary}/" \
    "${fixture_dir}/${configuration_file}"
  grep -Fq "permissions_boundary = ${replacement_boundary}" \
    "${fixture_dir}/${configuration_file}"
  assert_mutated_hcl_parses "${case_name}" "${fixture_dir}"

  if "${fixture_dir}/tests/test-static-security-contracts.sh" >"${test_log}" 2>&1; then
    printf 'FAIL %s: the static contract accepted a wrong role boundary.\n' "${case_name}" >&2
    exit 1
  fi
  if ! grep -Fq "${expected_error}" "${test_log}"; then
    printf 'FAIL %s: static test did not report the intended boundary contract.\n' "${case_name}" >&2
    cat "${test_log}" >&2
    exit 1
  fi

  record_case "${case_name}"
}

run_reintroduced_user_policy_negative() {
  local case_name="reintroduced-bootstrap-user-inline-policy"
  local fixture_dir="${mutation_root}/${case_name}/infra/bootstrap"
  local test_log="${mutation_root}/${case_name}.log"

  copy_static_fixture "${fixture_dir}"
  printf '%s\n' \
    'resource "aws_iam_user_policy" "unsafe_reintroduced" {' \
    '  name   = "unsafe-reintroduced"' \
    '  user   = data.aws_iam_user.bootstrap.user_name' \
    '  policy = jsonencode({ Version = "2012-10-17", Statement = [] })' \
    '}' >>"${fixture_dir}/unsafe-user-policy.tf"
  grep -Fq 'resource "aws_iam_user_policy" "unsafe_reintroduced"' \
    "${fixture_dir}/unsafe-user-policy.tf"
  assert_mutated_hcl_parses "${case_name}" "${fixture_dir}"

  if "${fixture_dir}/tests/test-static-security-contracts.sh" >"${test_log}" 2>&1; then
    printf 'FAIL %s: the resource allow-list accepted a user inline policy.\n' "${case_name}" >&2
    exit 1
  fi
  if ! grep -Fq 'Bootstrap resource inventory differs from the reviewed allow-list.' \
    "${test_log}"; then
    printf 'FAIL %s: static test did not report the intended contract.\n' "${case_name}" >&2
    cat "${test_log}" >&2
    exit 1
  fi

  record_case "${case_name}"
}

run_indented_runtime_resource_negative() {
  local case_name="indented-runtime-resource"
  local fixture_dir="${mutation_root}/${case_name}/infra/bootstrap"
  local test_log="${mutation_root}/${case_name}.log"

  copy_static_fixture "${fixture_dir}"
  printf '%s\n' \
    '  resource "aws_instance" "unsafe_runtime" {' \
    '    ami           = "synthetic"' \
    '    instance_type = "synthetic"' \
    '  }' >>"${fixture_dir}/unsafe-runtime.tf"
  grep -Fq '  resource "aws_instance" "unsafe_runtime" {' \
    "${fixture_dir}/unsafe-runtime.tf"
  assert_mutated_hcl_parses "${case_name}" "${fixture_dir}"

  if "${fixture_dir}/tests/test-static-security-contracts.sh" >"${test_log}" 2>&1; then
    printf 'FAIL %s: the resource inventory accepted an indented runtime resource.\n' \
      "${case_name}" >&2
    exit 1
  fi
  if ! grep -Fq 'Bootstrap resource inventory differs from the reviewed allow-list.' \
    "${test_log}"; then
    printf 'FAIL %s: static test did not report the intended contract.\n' \
      "${case_name}" >&2
    cat "${test_log}" >&2
    exit 1
  fi

  record_case "${case_name}"
}

run_budget_destroy_guard_negative() {
  local case_name="missing-budget-destroy-guard"
  local fixture_dir="${mutation_root}/${case_name}/infra/bootstrap"
  local test_log="${mutation_root}/${case_name}.log"

  copy_static_fixture "${fixture_dir}"
  perl -0pi -e 's/  lifecycle \{\n    prevent_destroy = true\n  \}\n//' \
    "${fixture_dir}/budget.tf"
  if grep -Fq 'prevent_destroy = true' "${fixture_dir}/budget.tf"; then
    printf 'FAIL %s: the budget destroy guard mutation was not applied.\n' \
      "${case_name}" >&2
    exit 1
  fi
  assert_mutated_hcl_parses "${case_name}" "${fixture_dir}"

  if "${fixture_dir}/tests/test-static-security-contracts.sh" >"${test_log}" 2>&1; then
    printf 'FAIL %s: the static contract accepted an unprotected budget.\n' \
      "${case_name}" >&2
    exit 1
  fi
  if ! grep -Fq 'Missing prevent_destroy on aws_budgets_budget.account_cost.' \
    "${test_log}"; then
    printf 'FAIL %s: static test did not report the missing budget guard.\n' \
      "${case_name}" >&2
    cat "${test_log}" >&2
    exit 1
  fi

  record_case "${case_name}"
}

run_destroy_guard_decoy_negative() {
  local case_name="destroy-guard-heredoc-decoy"
  local fixture_dir="${mutation_root}/${case_name}/infra/bootstrap"
  local test_log="${mutation_root}/${case_name}.log"

  copy_static_fixture "${fixture_dir}"
  perl -0pi -e 's/(resource "aws_s3_bucket" "state" \{.*?lifecycle \{\n)    prevent_destroy = true\n/$1/s' \
    "${fixture_dir}/state.tf"
  printf '%s\n' \
    '' \
    'locals {' \
    '  destroy_guard_decoy = <<-EOT' \
    '    lifecycle {' \
    '      prevent_destroy = true' \
    '    }' \
    '  EOT' \
    '}' >>"${fixture_dir}/state.tf"
  if python3 "${fixture_dir}/tests/inspect-hcl-structure.py" \
    "${fixture_dir}/state.tf" | jq -e '
      any(
        .attributes[];
        .resource == "aws_s3_bucket.state" and
        .parents == ["resource", "lifecycle"] and
        .name == "prevent_destroy"
      )
    ' >/dev/null; then
    printf 'FAIL %s: the state-bucket guard mutation was not applied.\n' \
      "${case_name}" >&2
    exit 1
  fi
  grep -Fq '  destroy_guard_decoy = <<-EOT' "${fixture_dir}/state.tf"
  test "$(grep -Fc 'prevent_destroy = true' "${fixture_dir}/state.tf")" -eq 7
  assert_mutated_hcl_parses "${case_name}" "${fixture_dir}"

  if "${fixture_dir}/tests/test-static-security-contracts.sh" >"${test_log}" 2>&1; then
    printf 'FAIL %s: a heredoc decoy satisfied the destroy guard.\n' \
      "${case_name}" >&2
    exit 1
  fi
  if ! grep -Fq 'Missing prevent_destroy on aws_s3_bucket.state.' \
    "${test_log}"; then
    printf 'FAIL %s: static test did not report the missing lifecycle guard.\n' \
      "${case_name}" >&2
    cat "${test_log}" >&2
    exit 1
  fi

  record_case "${case_name}"
}

run_lifecycle_filter_negative() {
  local case_name="narrowed-lifecycle-filter"
  local fixture_dir="${mutation_root}/${case_name}/infra/bootstrap"
  local test_log="${mutation_root}/${case_name}.log"

  copy_static_fixture "${fixture_dir}"
  perl -0pi -e 's/prefix = ""/prefix = "unrelated\/"/' \
    "${fixture_dir}/state.tf"
  grep -Fq 'prefix = "unrelated/"' "${fixture_dir}/state.tf"
  assert_mutated_hcl_parses "${case_name}" "${fixture_dir}"

  if "${fixture_dir}/tests/test-static-security-contracts.sh" >"${test_log}" 2>&1; then
    printf 'FAIL %s: the static contract accepted a narrowed lifecycle filter.\n' \
      "${case_name}" >&2
    exit 1
  fi
  if ! grep -Fq 'The state lifecycle filter differs from its exact all-object contract.' \
    "${test_log}"; then
    printf 'FAIL %s: static test did not report the lifecycle-filter contract.\n' \
      "${case_name}" >&2
    cat "${test_log}" >&2
    exit 1
  fi

  record_case "${case_name}"
}

run_terraform_negative \
  wildcard-oidc-subject-with-ignore-changes \
  'The raw GitHub trust-policy document must match the exact reviewed contract.'
run_terraform_negative \
  name-only-oidc-subject \
  'The raw GitHub trust-policy document must match the exact reviewed contract.'
run_terraform_negative \
  broadened-human-trust-with-ignore-changes \
  'The raw human trust-policy document must match the exact reviewed contract.'
run_terraform_negative \
  extra-oidc-audience \
  'The GitHub OIDC provider must expose only the exact token URL'
run_terraform_negative \
  delete-state-object \
  'The Terraform state object must permit only read and write access'
run_terraform_negative \
  extra-terraform-admin-action \
  'The Terraform administration policy must keep the exact state-bucket control'
run_terraform_negative \
  reintroduced-admin-bucket-policy \
  'The Terraform administration policy must keep the exact state-bucket control'
run_terraform_negative \
  extra-github-permission \
  'The Terraform state object must permit only read and write access'
run_terraform_negative \
  budget-sns-subscriber \
  'The budget must keep the exact email-only actual and forecast alerts'
run_terraform_negative \
  weakened-bucket-ownership \
  'The state bucket must keep its sole BucketOwnerEnforced ownership rule.'
run_terraform_negative \
  wrong-budget-name \
  'The account budget must keep its exact name, account'
run_terraform_negative \
  billing-view-wildcard \
  'primary billing-view ARN.'
run_terraform_negative \
  billing-view-prefix-wildcard \
  'primary billing-view ARN.'
run_terraform_negative \
  billing-view-wrong-account \
  'primary billing-view ARN.'
run_terraform_negative \
  billing-view-wrong-partition \
  'primary billing-view ARN.'
run_terraform_negative \
  billing-view-custom-arn \
  'primary billing-view ARN.'
run_terraform_negative \
  commercial-partition-broadening \
  'Missing expected failure' \
  'Error: Missing expected failure'

run_boundary_assignment_negative \
  replaced-human-boundary \
  human-access.tf \
  local.terraform_admin_boundary_arn \
  local.github_actions_boundary_arn \
  'The human role permissions-boundary assignment differs from its exact contract.'
run_boundary_assignment_negative \
  replaced-github-boundary \
  github-oidc.tf \
  local.github_actions_boundary_arn \
  local.terraform_admin_boundary_arn \
  'The GitHub role permissions-boundary assignment differs from its exact contract.'

run_policy_negative \
  extra-temporary-action \
  test-generate-temporary-policy.sh \
  'Temporary policy failed its security contract.'
run_policy_negative \
  extra-temporary-statement \
  test-generate-temporary-policy.sh \
  'Temporary policy failed its security contract.'
run_policy_negative \
  removed-temporary-expiry \
  test-generate-temporary-policy.sh \
  'Temporary policy failed its security contract.'
run_policy_negative \
  broadened-temporary-resource \
  test-generate-temporary-policy.sh \
  'Temporary policy failed its security contract.'
run_policy_negative \
  extra-github-boundary-action \
  test-generate-permissions-boundaries.sh \
  'GitHub Actions boundary failed its security contract.'
run_policy_negative \
  reintroduced-human-boundary-bucket-policy \
  test-generate-permissions-boundaries.sh \
  'Terraform administration boundary failed its security contract.'
run_policy_negative \
  longer-temporary-expiry \
  test-generate-temporary-policy.sh \
  'Temporary policy lifetime must not exceed four hours.'

run_reintroduced_user_policy_negative
run_indented_runtime_resource_negative
run_structural_static_negative \
  comment-separated-resource-header \
  'Bootstrap resource inventory differs from the reviewed allow-list.'
run_structural_static_negative \
  comment-separated-module-header \
  'Bootstrap configuration must not load unreviewed root modules.'
run_structural_static_negative \
  resource-provisioner \
  'Bootstrap resources must not use provisioners.'
run_structural_static_negative \
  lifecycle-ignore-changes \
  'Bootstrap resources must not use ignore_changes.'
run_structural_static_negative \
  future-budget-start \
  'The account budget must omit optional activation, billing-view and adjustment settings.'
run_structural_static_negative \
  provider-assume-role \
  'The AWS provider must use only the exact ambient-credential configuration.'
run_structural_static_negative \
  provider-assume-role-with-web-identity \
  'The AWS provider must use only the exact ambient-credential configuration.'
run_structural_static_negative \
  provider-profile \
  'The AWS provider must use only the exact ambient-credential configuration.'
run_structural_static_negative \
  backend-example-profile \
  'The partial S3 backend example must contain no credential, profile or role-assumption configuration.'
run_structural_static_negative \
  backend-example-role-assumption \
  'The partial S3 backend example must contain no credential, profile or role-assumption configuration.'
run_structural_static_negative \
  budget-email-default \
  'The budget notification email must be sensitive and have no tracked default.'
run_structural_static_negative \
  budget-email-commented-default \
  'The budget notification email must be sensitive and have no tracked default.'
run_structural_static_negative \
  hard-coded-provider-region \
  'The AWS provider must use the exact region and expected account inputs.'
run_structural_static_negative \
  removed-account-allow-list \
  'The AWS provider must use the exact region and expected account inputs.'
run_budget_destroy_guard_negative
run_destroy_guard_decoy_negative
run_lifecycle_filter_negative

printf 'Security-contract mutations detected: %d/45.\n' "${negative_case_count}"
