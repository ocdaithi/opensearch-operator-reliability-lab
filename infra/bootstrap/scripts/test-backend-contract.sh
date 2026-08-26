#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
contract_script="${source_root}/infra/bootstrap/scripts/check-backend-contract.sh"
local_template="${source_root}/infra/bootstrap/backend.local.tf.example"
s3_template="${source_root}/infra/bootstrap/backend.s3.tf.example"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
negative_case_count=0
synthetic_account_id="$(printf '%s%s%s' 0000 0000 0000)"
synthetic_bucket_name="opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"
synthetic_role_arn="arn:aws:iam::${synthetic_account_id}:role/opensearch-lab-terraform-admin"

record_negative_case() {
  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: %s\n' "$1"
}

expect_contract_failure() {
  local case_name="$1"
  local contract="$2"
  local candidate_file="$3"
  local expected_diagnostic="$4"
  local contract_output

  if contract_output="$(
    TF_STATE_BUCKET_NAME="${synthetic_bucket_name}" \
      TF_ADMIN_ROLE_ARN="${synthetic_role_arn}" \
      "${contract_script}" "${contract}" "${candidate_file}" 2>&1
  )"; then
    echo "Backend contract unexpectedly accepted: ${case_name}" >&2
    exit 1
  fi
  if [[ "${contract_output}" != "${expected_diagnostic}" ]]; then
    printf 'Backend contract failed with an unexpected diagnostic for %s.\n' \
      "${case_name}" >&2
    printf 'Expected: %s\n' "${expected_diagnostic}" >&2
    printf 'Actual: %s\n' "${contract_output:-<no output>}" >&2
    exit 1
  fi
  record_negative_case "${case_name}"
}

"${contract_script}" local "${local_template}" >/dev/null
"${contract_script}" s3-template "${s3_template}" >/dev/null

resolved_backend="${test_root}/resolved.tf"
sed "s/__TF_STATE_BUCKET_NAME__/${synthetic_bucket_name}/" \
  "${s3_template}" >"${resolved_backend}"
TF_STATE_BUCKET_NAME="${synthetic_bucket_name}" \
  "${contract_script}" s3-resolved "${resolved_backend}" >/dev/null

migration_backend="${test_root}/migration.tf"
cat >"${migration_backend}" <<EOF
terraform {
  backend "s3" {
    bucket       = "${synthetic_bucket_name}"
    key          = "bootstrap/terraform.tfstate"
    profile      = "opensearch-lab-terraform"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true

    assume_role = {
      role_arn     = "${synthetic_role_arn}"
      session_name = "terraform-bootstrap-state"
    }
  }
}
EOF
TF_STATE_BUCKET_NAME="${synthetic_bucket_name}" \
  TF_ADMIN_ROLE_ARN="${synthetic_role_arn}" \
  "${contract_script}" s3-migration "${migration_backend}" >/dev/null

wrong_local_path="${test_root}/wrong-local-path.tf"
sed 's#../../.private/terraform-bootstrap/terraform.tfstate#terraform.tfstate#' \
  "${local_template}" >"${wrong_local_path}"
grep -Fq 'path = "terraform.tfstate"' "${wrong_local_path}"
expect_contract_failure \
  "unexpected-local-state-path" \
  local \
  "${wrong_local_path}" \
  "The local backend does not match its exact reviewed contract."

extra_s3_setting="${test_root}/extra-s3-setting.tf"
awk '
  { print }
  /use_lockfile = true/ { print "    profile      = \"unexpected\"" }
' "${s3_template}" >"${extra_s3_setting}"
grep -Fq 'profile      = "unexpected"' "${extra_s3_setting}"
expect_contract_failure \
  "extra-s3-setting" \
  s3-template \
  "${extra_s3_setting}" \
  "The s3-template backend does not match its exact reviewed contract."

wrong_state_key="${test_root}/wrong-state-key.tf"
sed 's#bootstrap/terraform.tfstate#terraform.tfstate#' \
  "${s3_template}" >"${wrong_state_key}"
grep -Fq 'key          = "terraform.tfstate"' "${wrong_state_key}"
expect_contract_failure \
  "unexpected-state-key" \
  s3-template \
  "${wrong_state_key}" \
  "The s3-template backend does not match its exact reviewed contract."

unencrypted_backend="${test_root}/unencrypted.tf"
sed 's/encrypt      = true/encrypt      = false/' \
  "${resolved_backend}" >"${unencrypted_backend}"
grep -Fq 'encrypt      = false' "${unencrypted_backend}"
expect_contract_failure \
  "backend-encryption-disabled" \
  s3-resolved \
  "${unencrypted_backend}" \
  "The s3-resolved backend does not match its exact reviewed contract."

wrong_migration_profile="${test_root}/wrong-migration-profile.tf"
sed 's/profile      = "opensearch-lab-terraform"/profile      = "default"/' \
  "${migration_backend}" >"${wrong_migration_profile}"
grep -Fq 'profile      = "default"' "${wrong_migration_profile}"
expect_contract_failure \
  "unexpected-migration-profile" \
  s3-migration \
  "${wrong_migration_profile}" \
  "The s3-migration backend does not match its exact reviewed contract."

wrong_migration_session="${test_root}/wrong-migration-session.tf"
sed 's/session_name = "terraform-bootstrap-state"/session_name = "unexpected"/' \
  "${migration_backend}" >"${wrong_migration_session}"
grep -Fq 'session_name = "unexpected"' "${wrong_migration_session}"
expect_contract_failure \
  "unexpected-migration-session" \
  s3-migration \
  "${wrong_migration_session}" \
  "The s3-migration backend does not match its exact reviewed contract."

wrong_role_arn="arn:aws:iam::${synthetic_account_id}:role/unexpected"
wrong_migration_role="${test_root}/wrong-migration-role.tf"
sed "s#${synthetic_role_arn}#${wrong_role_arn}#" \
  "${migration_backend}" >"${wrong_migration_role}"
grep -Fq "role_arn     = \"${wrong_role_arn}\"" "${wrong_migration_role}"
expect_contract_failure \
  "unexpected-migration-role" \
  s3-migration \
  "${wrong_migration_role}" \
  "The s3-migration backend does not match its exact reviewed contract."

printf 'Exact backend contracts passed (%d negative cases).\n' \
  "${negative_case_count}"
