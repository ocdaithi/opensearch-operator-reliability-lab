#!/usr/bin/env bash
set -euo pipefail

bootstrap_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
terraform_bin="${TERRAFORM_BIN:-terraform}"

if ! compgen -G "$bootstrap_dir/.terraform/providers/registry.terraform.io/hashicorp/aws/6.61.0/*/terraform-provider-aws_*" >/dev/null; then
  printf 'Run terraform init -backend=false before the mutation tests.\n' >&2
  exit 1
fi

mutation_root="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-security-mutations.XXXXXX")"
trap 'rm -rf "$mutation_root"' EXIT

copy_fixture() {
  local fixture_dir="$1"
  mkdir -p "$fixture_dir/tests"

  for source_file in "$bootstrap_dir"/*.tf; do
    if [[ "$(basename "$source_file")" != "backend.tf" ]]; then
      cp "$source_file" "$fixture_dir/"
    fi
  done

  cp "$bootstrap_dir/.terraform.lock.hcl" "$fixture_dir/"
  cp "$bootstrap_dir/tests/security_contracts.tftest.hcl" "$fixture_dir/tests/"
  ln -s "$bootstrap_dir/.terraform" "$fixture_dir/.terraform"
}

apply_mutation() {
  local case_name="$1"
  local fixture_dir="$2"

  case "$case_name" in
    wildcard_oidc_subject)
      perl -0pi -e 's#github_subject = "[^"]+"#github_subject = "repo:*"#' "$fixture_dir/locals.tf"
      grep -Fq 'github_subject = "repo:*"' "$fixture_dir/locals.tf"
      ;;
    extra_oidc_audience)
      perl -0pi -e 's/client_id_list = \["sts\.amazonaws\.com"\]/client_id_list = ["sts.amazonaws.com", "example.invalid"]/' "$fixture_dir/github-oidc.tf"
      grep -Fq 'client_id_list = ["sts.amazonaws.com", "example.invalid"]' "$fixture_dir/github-oidc.tf"
      ;;
    delete_state_object)
      perl -0pi -e 's/(sid\s+= "ReadAndWriteTerraformState".*?actions = \[\n\s+"s3:GetObject",\n)/$1      "s3:DeleteObject",\n/s' "$fixture_dir/backend-access.tf"
      grep -A8 -F 'sid    = "ReadAndWriteTerraformState"' "$fixture_dir/backend-access.tf" | grep -Fq '"s3:DeleteObject"'
      ;;
    broaden_bootstrap_user_policy)
      perl -0pi -e 's/resources = \[aws_iam_role\.terraform_admin\.arn\]/resources = ["*"]/' "$fixture_dir/human-access.tf"
      grep -Fq 'resources = ["*"]' "$fixture_dir/human-access.tf"
      ;;
    *)
      printf 'Unknown mutation case: %s\n' "$case_name" >&2
      exit 1
      ;;
  esac
}

run_negative_case() {
  local case_name="$1"
  local expected_error="$2"
  local fixture_dir="$mutation_root/$case_name"
  local test_log="$mutation_root/$case_name.log"

  copy_fixture "$fixture_dir"
  apply_mutation "$case_name" "$fixture_dir"

  set +e
  AWS_EC2_METADATA_DISABLED=true \
    AWS_ENDPOINT_URL=http://127.0.0.1:9 \
    "$terraform_bin" -chdir="$fixture_dir" test -no-color >"$test_log" 2>&1
  local test_status=$?
  set -e

  if [[ $test_status -eq 0 ]]; then
    printf 'FAIL %s: unsafe mutation passed the contract suite.\n' "$case_name" >&2
    exit 1
  fi

  if ! grep -Fq "$expected_error" "$test_log"; then
    printf 'FAIL %s: suite failed for an unexpected reason.\n' "$case_name" >&2
    tail -40 "$test_log" >&2
    exit 1
  fi

  printf 'PASS negative case: %s\n' "$case_name"
}

run_negative_case \
  wildcard_oidc_subject \
  'The GitHub role trust must require the exact immutable repository'
run_negative_case \
  extra_oidc_audience \
  'The GitHub OIDC provider must expose only the exact token URL'
run_negative_case \
  delete_state_object \
  'The Terraform state object must permit only read and write access'
run_negative_case \
  broaden_bootstrap_user_policy \
  'The persistent bootstrap-user policy must allow only assumption'

printf 'Security-contract mutations detected: 4/4.\n'
