#!/usr/bin/env bash

set -euo pipefail

bootstrap_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository_root="$(git -C "${bootstrap_dir}" rev-parse --show-toplevel)"
terraform_bin="${TERRAFORM_BIN:-terraform}"
negative_case_count=0

if ! compgen -G "${bootstrap_dir}/.terraform/providers/registry.terraform.io/hashicorp/aws/6.61.0/*/terraform-provider-aws_*" >/dev/null; then
  printf 'Run terraform init -backend=false before the mutation tests.\n' >&2
  exit 1
fi

mutation_root="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-security-mutations.XXXXXX")"
trap 'rm -rf -- "${mutation_root}"' EXIT

record_case() {
  negative_case_count=$((negative_case_count + 1))
  printf 'PASS negative case: %s\n' "$1"
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
  ln -s "${bootstrap_dir}/.terraform" "${fixture_dir}/.terraform"
}

apply_terraform_mutation() {
  local case_name="$1"
  local fixture_dir="$2"
  local mutated_file="${fixture_dir}/mutation.tmp"
  local synthetic_account_id
  local synthetic_topic_arn

  case "${case_name}" in
    wildcard-oidc-subject)
      perl -0pi -e 's#github_subject = "[^"]+"#github_subject = "repo:*"#' "${fixture_dir}/locals.tf"
      grep -Fq 'github_subject = "repo:*"' "${fixture_dir}/locals.tf"
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
    *)
      printf 'Unknown Terraform mutation case: %s\n' "${case_name}" >&2
      exit 1
      ;;
  esac
}

run_terraform_negative() {
  local case_name="$1"
  local expected_error="$2"
  local fixture_dir="${mutation_root}/${case_name}"
  local test_log="${mutation_root}/${case_name}.log"
  local test_status

  copy_terraform_fixture "${fixture_dir}"
  apply_terraform_mutation "${case_name}" "${fixture_dir}"

  set +e
  AWS_EC2_METADATA_DISABLED=true \
    AWS_ENDPOINT_URL=http://127.0.0.1:9 \
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
  if grep -Eq 'Error: (Failed to install|Failed to load|Inconsistent dependency|Invalid|Missing required|Reference to undeclared|Unsupported)' "${test_log}"; then
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
  git -C "${fixture_dir}" init -q
  cp "${repository_root}/.gitignore" "${fixture_dir}/.gitignore"
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
  cp "${bootstrap_dir}/scripts/policy-contract-digest.sh" \
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

  mkdir -p "${fixture_dir}/tests"
  cp "${bootstrap_dir}"/*.tf "${fixture_dir}/"
  cp "${bootstrap_dir}/tests/test-static-security-contracts.sh" "${fixture_dir}/tests/"
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

run_destroy_guard_decoy_negative() {
  local case_name="destroy-guard-heredoc-decoy"
  local fixture_dir="${mutation_root}/${case_name}/infra/bootstrap"
  local test_log="${mutation_root}/${case_name}.log"

  copy_static_fixture "${fixture_dir}"
  perl -0pi -e 's/  lifecycle \{\n    prevent_destroy = true\n  \}/  tags = {\n    Decoy = <<-EOT\n      lifecycle {\n        prevent_destroy = true\n      }\n    EOT\n  }/' \
    "${fixture_dir}/state.tf"
  grep -Fq '    Decoy = <<-EOT' "${fixture_dir}/state.tf"
  test "$(grep -Fc 'prevent_destroy = true' "${fixture_dir}/state.tf")" -eq 7

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
  wildcard-oidc-subject \
  'The GitHub role trust must require the exact immutable repository'
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
  'The temporary policy template differs from its exact reviewed contract.'
run_policy_negative \
  extra-temporary-statement \
  test-generate-temporary-policy.sh \
  'The temporary policy template differs from its exact reviewed contract.'
run_policy_negative \
  removed-temporary-expiry \
  test-generate-temporary-policy.sh \
  'The temporary policy template differs from its exact reviewed contract.'
run_policy_negative \
  broadened-temporary-resource \
  test-generate-temporary-policy.sh \
  'The temporary policy template differs from its exact reviewed contract.'
run_policy_negative \
  extra-github-boundary-action \
  test-generate-permissions-boundaries.sh \
  'A permissions-boundary template differs from its exact reviewed contract.'
run_policy_negative \
  reintroduced-human-boundary-bucket-policy \
  test-generate-permissions-boundaries.sh \
  'A permissions-boundary template differs from its exact reviewed contract.'

run_reintroduced_user_policy_negative
run_indented_runtime_resource_negative
run_destroy_guard_decoy_negative
run_lifecycle_filter_negative

printf 'Security-contract mutations detected: %d/20.\n' "${negative_case_count}"
