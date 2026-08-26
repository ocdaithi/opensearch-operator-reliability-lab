#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
negative_case_count=0

record_negative_case() {
  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: %s\n' "$1"
}

make_fixture() {
  fixture_name="$1"
  fixture_root="${test_root}/${fixture_name}"

  mkdir -p \
    "${fixture_root}/bin" \
    "${fixture_root}/infra/bootstrap/.terraform" \
    "${fixture_root}/infra/bootstrap/scripts" \
    "${fixture_root}/.private/terraform-bootstrap"
  git -C "${fixture_root}" init -q
  cp "${source_root}/infra/bootstrap/scripts/migrate-state.sh" \
    "${fixture_root}/infra/bootstrap/scripts/migrate-state.sh"
  cp "${source_root}/infra/bootstrap/scripts/check-backend-contract.sh" \
    "${fixture_root}/infra/bootstrap/scripts/check-backend-contract.sh"
  cp "${source_root}/infra/bootstrap/backend.local.tf.example" \
    "${fixture_root}/infra/bootstrap/backend.tf"
  cp "${source_root}/infra/bootstrap/backend.local.tf.example" \
    "${fixture_root}/infra/bootstrap/backend.local.tf.example"
  printf 'budget_notification_email = "private@example.com"\n' \
    >"${fixture_root}/.private/terraform-bootstrap/terraform.tfvars"
  printf '%s\n' \
    '{"version":4,"terraform_version":"1.15.9","serial":4,"lineage":"fixture-lineage","outputs":{"fixture":{"value":"unchanged","type":"string"}},"resources":[]}' \
    >"${fixture_root}/.private/terraform-bootstrap/terraform.tfstate"
  cp "${fixture_root}/.private/terraform-bootstrap/terraform.tfstate" \
    "${fixture_root}/expected-local-state.tfstate"
  printf '%s\n' '{"backend":{"type":"local"},"fixture":"validated-local-cache"}' \
    >"${fixture_root}/expected-backend-cache.tfstate"
  cp "${fixture_root}/expected-backend-cache.tfstate" \
    "${fixture_root}/infra/bootstrap/.terraform/terraform.tfstate"
  chmod 600 \
    "${fixture_root}/.private/terraform-bootstrap/terraform.tfstate" \
    "${fixture_root}/infra/bootstrap/.terraform/terraform.tfstate"
  cp "${fixture_root}/infra/bootstrap/backend.tf" "${fixture_root}/expected-backend.tf"

  cat >"${fixture_root}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s|%s\n' "${TF_VAR_terraform_admin_role_arn:-unset}" "$*" >>"${FAKE_LOG}"

if [[ "${AWS_PROFILE:-}" != "opensearch-lab-terraform" ]]; then
  exit 43
fi

fixture_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend_file="${fixture_root}/infra/bootstrap/backend.tf"
backend_cache="${fixture_root}/infra/bootstrap/.terraform/terraform.tfstate"
local_state="${fixture_root}/.private/terraform-bootstrap/terraform.tfstate"
expected_local_state="${fixture_root}/expected-local-state.tfstate"

case "$*" in
  *" init -migrate-state "*)
    printf '%s\n' '{"backend":{"type":"s3"},"fixture":"remote-cache"}' >"${backend_cache}"
    rm -f -- "${local_state}"
    if [[ "${FAKE_MIGRATION_FAILURE:-false}" == "true" ]]; then
      exit 42
    fi
    ;;
  *" init -reconfigure "*)
    cp "${fixture_root}/expected-backend-cache.tfstate" "${backend_cache}"
    ;;
  *" workspace show")
    printf '%s\n' "${FAKE_WORKSPACE:-default}"
    ;;
  *" workspace list")
    printf '* default\n'
    if [[ "${FAKE_EXTRA_WORKSPACE:-false}" == "true" ]]; then
      printf '  inactive\n'
    fi
    ;;
  *" state pull")
    if grep -Fq 'backend "s3"' "${backend_file}"; then
      case "${FAKE_STATE_VERIFICATION:-valid}" in
        lineage-mismatch)
          jq -c '.terraform_version = "1.16.0" | .lineage = "unexpected-lineage"' "${expected_local_state}"
          ;;
        serial-regression)
          jq -c '.terraform_version = "1.16.0" | .serial = 3' "${expected_local_state}"
          ;;
        serial-advance)
          jq -c '.terraform_version = "1.16.0" | .serial = 5' "${expected_local_state}"
          ;;
        semantic-mismatch)
          jq -c '.terraform_version = "1.16.0" | .outputs.fixture.value = "changed"' "${expected_local_state}"
          ;;
        terraform-version-missing)
          jq -c 'del(.terraform_version)' "${expected_local_state}"
          ;;
        *)
          jq -c '.terraform_version = "1.16.0"' "${expected_local_state}"
          ;;
      esac
    else
      if [[ "${FAKE_STATE_VERIFICATION:-valid}" == "local-recovery-mismatch" ]]; then
        jq -c '.terraform_version = "1.16.0" | .outputs.fixture.value = "changed"' "${local_state}"
      else
        jq -c '.terraform_version = "1.16.0"' "${local_state}"
      fi
    fi
    ;;
  *" plan "*)
    if [[ "$*" != *" -detailed-exitcode "* ]]; then
      exit 45
    fi
    for argument in "$@"; do
      case "${argument}" in
        -out=*)
          : >"${argument#-out=}"
          ;;
      esac
    done
    if [[ "${FAKE_DELETE_BACKEND_RECOVERY:-false}" == "true" ]]; then
      rm -f -- "${fixture_root}"/.private/terraform-bootstrap/pre-migration-backend-*.tf
    fi
    if [[ "${FAKE_DELETE_CACHE_RECOVERY:-false}" == "true" ]]; then
      rm -f -- "${fixture_root}"/.private/terraform-bootstrap/pre-migration-backend-cache-*.tfstate
    fi
    exit "${FAKE_PLAN_EXIT_CODE:-0}"
    ;;
  *" output -raw state_bucket_name")
    printf '%s\n' "${FAKE_STATE_BUCKET_OUTPUT:-opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1}"
    ;;
  *" output -raw terraform_admin_role_arn")
    account_id="$(printf '%06d%06d' 123 456)"
    printf 'arn:aws:iam::%s:role/opensearch-lab-terraform-admin\n' "${account_id}"
    ;;
  *)
    printf 'Unexpected fake Terraform command: %s\n' "$*" >&2
    exit 97
    ;;
esac
EOF

  cat >"${fixture_root}/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'unset|%s\n' "$*" >>"${FAKE_LOG}"
case "$*" in
  *" --prefix bootstrap/terraform.tfstate.tflock "*)
    if [[ "${FAKE_RESIDUAL_LOCK:-false}" == "true" ]]; then
      printf '{"Contents":[{"Key":"bootstrap/terraform.tfstate.tflock"}]}\n'
    else
      printf '{"Contents":[]}\n'
    fi
    ;;
  *" --prefix bootstrap/terraform.tfstate "*)
    if [[ "${FAKE_REMOTE_STATE:-empty}" == "present" ]]; then
      printf '{"Contents":[{"Key":"bootstrap/terraform.tfstate"}]}\n'
    else
      printf '{"Contents":[]}\n'
    fi
    ;;
  *)
    printf 'Unexpected fake AWS command: %s\n' "$*" >&2
    exit 98
    ;;
esac
EOF

  cat >"${fixture_root}/bin/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

/bin/cp "$@"

arguments=("$@")
destination="${arguments[${#arguments[@]} - 1]}"
if [[ "${FAKE_CORRUPT_LOCAL_STATE_RESTORE:-false}" == "true" &&
  "${destination}" == */terraform.tfstate.rollback.* ]]; then
  corrupt_state="${destination}.corrupt"
  jq -c '.outputs.fixture.value = "rollback-corrupted"' "${destination}" >"${corrupt_state}"
  chmod 600 "${corrupt_state}"
  /bin/mv "${corrupt_state}" "${destination}"
fi
EOF

  chmod 700 \
    "${fixture_root}/bin/terraform" \
    "${fixture_root}/bin/aws" \
    "${fixture_root}/bin/cp"
  printf '%s\n' "${fixture_root}"
}

assert_local_backend_restored() {
  local fixture_root="$1"

  cmp -s "${fixture_root}/expected-backend.tf" \
    "${fixture_root}/infra/bootstrap/backend.tf"
  cmp -s "${fixture_root}/expected-backend-cache.tfstate" \
    "${fixture_root}/infra/bootstrap/.terraform/terraform.tfstate"
  jq -e -s '
    .[0].lineage == .[1].lineage
    and .[0].serial == .[1].serial
    and (.[0] | del(.terraform_version)) == (.[1] | del(.terraform_version))
  ' "${fixture_root}/expected-local-state.tfstate" \
    "${fixture_root}/.private/terraform-bootstrap/terraform.tfstate" >/dev/null
  assert_mode_600 "${fixture_root}/.private/terraform-bootstrap/terraform.tfstate"
}

assert_mode_600() {
  local file="$1"
  local mode

  if stat -f '%Lp' "${file}" >/dev/null 2>&1; then
    mode="$(stat -f '%Lp' "${file}")"
  else
    mode="$(stat -c '%a' "${file}")"
  fi
  test "${mode}" = "600"
}

assert_expected_failure_output() {
  local case_name="$1"
  local output_file="$2"
  local expected_diagnostic="$3"

  if ! grep -Fq "${expected_diagnostic}" "${output_file}"; then
    printf 'Negative case %s did not report its expected diagnostic.\n' \
      "${case_name}" >&2
    cat "${output_file}" >&2
    exit 1
  fi

  if grep -Eq \
    'Unexpected fake (AWS|Terraform) command|Required command is unavailable:|command not found|unbound variable' \
    "${output_file}"; then
    printf 'Negative case %s encountered an unrelated fixture failure.\n' \
      "${case_name}" >&2
    cat "${output_file}" >&2
    exit 1
  fi
}

success_fixture="$(make_fixture success)"
success_log="${success_fixture}/commands.log"
PATH="${success_fixture}/bin:${PATH}" FAKE_LOG="${success_log}" \
  "${success_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved >/dev/null

grep -Fq 'assume_role = {' "${success_fixture}/infra/bootstrap/backend.tf"
grep -Fq 'profile      = "opensearch-lab-terraform"' "${success_fixture}/infra/bootstrap/backend.tf"
grep -Fq 'role/opensearch-lab-terraform-admin' "${success_fixture}/infra/bootstrap/backend.tf"
grep -Eq '^arn:aws:iam::[0-9]{12}:role/opensearch-lab-terraform-admin\|.* plan ' "${success_log}"
grep -Fq -- '-detailed-exitcode' "${success_log}"
grep -Fq 's3api list-objects-v2 --profile opensearch-lab-terraform' "${success_log}"
grep -Fq -- '--prefix bootstrap/terraform.tfstate.tflock' "${success_log}"
test -s "$(find "${success_fixture}/.private/terraform-bootstrap" -name 'pre-migration-*.tfstate' -print -quit)"
grep -Fq '"fixture":"remote-cache"' \
  "${success_fixture}/infra/bootstrap/.terraform/terraform.tfstate"

recovery_count=0
while IFS= read -r recovery_file; do
  assert_mode_600 "${recovery_file}"
  recovery_count=$((recovery_count + 1))
done < <(
  find "${success_fixture}/.private/terraform-bootstrap" -type f \
    \( -name 'pre-migration-*' -o -name 'post-migration-*' \) -print
)
test "${recovery_count}" -ge 5

approval_fixture="$(make_fixture approval)"
approval_error="${approval_fixture}/migration-error.txt"
cp "${approval_fixture}/infra/bootstrap/backend.tf" "${approval_fixture}/expected-backend.tf"
if PATH="${approval_fixture}/bin:${PATH}" \
  FAKE_LOG="${approval_fixture}/commands.log" \
  "${approval_fixture}/infra/bootstrap/scripts/migrate-state.sh" \
  >/dev/null 2>"${approval_error}"; then
  echo "Migration unexpectedly ran without explicit approval." >&2
  exit 1
fi
assert_expected_failure_output \
  "missing-explicit-approval" \
  "${approval_error}" \
  "Refusing to migrate state without the explicit --approved flag."
assert_local_backend_restored "${approval_fixture}"
record_negative_case "missing-explicit-approval"

backend_fixture="$(make_fixture unexpected-backend)"
backend_error="${backend_fixture}/migration-error.txt"
printf 'terraform { backend "local" { path = "unexpected.tfstate" } }\n' \
  >"${backend_fixture}/infra/bootstrap/backend.tf"
cp "${backend_fixture}/infra/bootstrap/backend.tf" "${backend_fixture}/expected-backend.tf"
if PATH="${backend_fixture}/bin:${PATH}" \
  FAKE_LOG="${backend_fixture}/commands.log" \
  "${backend_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${backend_error}"; then
  echo "Migration unexpectedly accepted an unrecognised local backend." >&2
  exit 1
fi
assert_expected_failure_output \
  "unexpected-local-backend" \
  "${backend_error}" \
  "The local backend does not match its exact reviewed contract."
assert_local_backend_restored "${backend_fixture}"
record_negative_case "unexpected-local-backend"

occupied_fixture="$(make_fixture occupied)"
occupied_error="${occupied_fixture}/migration-error.txt"
cp "${occupied_fixture}/infra/bootstrap/backend.tf" "${occupied_fixture}/expected-backend.tf"
if PATH="${occupied_fixture}/bin:${PATH}" \
  FAKE_LOG="${occupied_fixture}/commands.log" \
  FAKE_REMOTE_STATE=present \
  "${occupied_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${occupied_error}"; then
  echo "Migration unexpectedly accepted an occupied destination." >&2
  exit 1
fi
assert_expected_failure_output \
  "occupied-remote-destination" \
  "${occupied_error}" \
  "The remote state destination is not empty; no migration was attempted."
assert_local_backend_restored "${occupied_fixture}"
record_negative_case "occupied-remote-destination"

mismatched_destination_fixture="$(make_fixture mismatched-destination)"
mismatched_destination_error="${mismatched_destination_fixture}/migration-error.txt"
if PATH="${mismatched_destination_fixture}/bin:${PATH}" \
  FAKE_LOG="${mismatched_destination_fixture}/commands.log" \
  FAKE_STATE_BUCKET_OUTPUT="opensearch-lab-tfstate-unexpected-eu-west-1" \
  "${mismatched_destination_fixture}/infra/bootstrap/scripts/migrate-state.sh" \
  --approved >/dev/null 2>"${mismatched_destination_error}"; then
  echo "Migration unexpectedly accepted an unreviewed destination bucket." >&2
  exit 1
fi
assert_expected_failure_output \
  "unexpected-destination-before-aws" \
  "${mismatched_destination_error}" \
  "TF_STATE_BUCKET_NAME is missing or differs from the deterministic bucket contract."
if grep -Fq '|s3api ' "${mismatched_destination_fixture}/commands.log"; then
  echo "Migration contacted S3 before validating the destination account." >&2
  exit 1
fi
assert_local_backend_restored "${mismatched_destination_fixture}"
record_negative_case "unexpected-destination-before-aws"

rollback_fixture="$(make_fixture rollback)"
rollback_error="${rollback_fixture}/migration-error.txt"
cp "${rollback_fixture}/infra/bootstrap/backend.tf" "${rollback_fixture}/expected-backend.tf"
if PATH="${rollback_fixture}/bin:${PATH}" \
  FAKE_LOG="${rollback_fixture}/commands.log" \
  FAKE_MIGRATION_FAILURE=true \
  "${rollback_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${rollback_error}"; then
  echo "Migration failure was not propagated." >&2
  exit 1
fi
assert_expected_failure_output \
  "migration-command-failure" \
  "${rollback_error}" \
  "Migration failed; backend.tf and cached backend metadata were restored."
grep -Fq ' init -migrate-state ' "${rollback_fixture}/commands.log"
assert_local_backend_restored "${rollback_fixture}"
record_negative_case "migration-command-failure"

local_state_fixture="$(make_fixture local-recovery-mismatch)"
local_state_error="${local_state_fixture}/migration-error.txt"
if PATH="${local_state_fixture}/bin:${PATH}" \
  FAKE_LOG="${local_state_fixture}/commands.log" \
  FAKE_STATE_VERIFICATION=local-recovery-mismatch \
  "${local_state_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${local_state_error}"; then
  echo "Migration unexpectedly accepted a recovery copy which differed from local state." >&2
  exit 1
fi
assert_expected_failure_output \
  "local-state-recovery-mismatch" \
  "${local_state_error}" \
  "The original local state does not match its recovery copy."
assert_local_backend_restored "${local_state_fixture}"
record_negative_case "local-state-recovery-mismatch"

lineage_fixture="$(make_fixture lineage-mismatch)"
lineage_error="${lineage_fixture}/migration-error.txt"
if PATH="${lineage_fixture}/bin:${PATH}" \
  FAKE_LOG="${lineage_fixture}/commands.log" \
  FAKE_STATE_VERIFICATION=lineage-mismatch \
  "${lineage_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${lineage_error}"; then
  echo "Migration unexpectedly accepted a changed state lineage." >&2
  exit 1
fi
assert_expected_failure_output \
  "state-lineage-mismatch" \
  "${lineage_error}" \
  "Remote state differs from the recovered local state."
assert_local_backend_restored "${lineage_fixture}"
record_negative_case "state-lineage-mismatch"

serial_fixture="$(make_fixture serial-regression)"
serial_error="${serial_fixture}/migration-error.txt"
if PATH="${serial_fixture}/bin:${PATH}" \
  FAKE_LOG="${serial_fixture}/commands.log" \
  FAKE_STATE_VERIFICATION=serial-regression \
  "${serial_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${serial_error}"; then
  echo "Migration unexpectedly accepted a regressed state serial." >&2
  exit 1
fi
assert_expected_failure_output \
  "state-serial-regression" \
  "${serial_error}" \
  "Remote state differs from the recovered local state."
assert_local_backend_restored "${serial_fixture}"
record_negative_case "state-serial-regression"

serial_advance_fixture="$(make_fixture serial-advance)"
serial_advance_error="${serial_advance_fixture}/migration-error.txt"
if PATH="${serial_advance_fixture}/bin:${PATH}" \
  FAKE_LOG="${serial_advance_fixture}/commands.log" \
  FAKE_STATE_VERIFICATION=serial-advance \
  "${serial_advance_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${serial_advance_error}"; then
  echo "Migration unexpectedly accepted an advanced state serial." >&2
  exit 1
fi
assert_expected_failure_output \
  "state-serial-advance" \
  "${serial_advance_error}" \
  "Remote state differs from the recovered local state."
assert_local_backend_restored "${serial_advance_fixture}"
record_negative_case "state-serial-advance"

semantic_fixture="$(make_fixture semantic-mismatch)"
semantic_error="${semantic_fixture}/migration-error.txt"
if PATH="${semantic_fixture}/bin:${PATH}" \
  FAKE_LOG="${semantic_fixture}/commands.log" \
  FAKE_STATE_VERIFICATION=semantic-mismatch \
  "${semantic_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${semantic_error}"; then
  echo "Migration unexpectedly accepted semantically different remote state." >&2
  exit 1
fi
assert_expected_failure_output \
  "state-semantic-mismatch" \
  "${semantic_error}" \
  "Remote state differs from the recovered local state."
assert_local_backend_restored "${semantic_fixture}"
record_negative_case "state-semantic-mismatch"

version_field_fixture="$(make_fixture terraform-version-missing)"
version_field_error="${version_field_fixture}/migration-error.txt"
if PATH="${version_field_fixture}/bin:${PATH}" \
  FAKE_LOG="${version_field_fixture}/commands.log" \
  FAKE_STATE_VERIFICATION=terraform-version-missing \
  "${version_field_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${version_field_error}"; then
  echo "Migration unexpectedly accepted a state without terraform_version." >&2
  exit 1
fi
assert_expected_failure_output \
  "state-terraform-version-field-missing" \
  "${version_field_error}" \
  "Remote state differs from the recovered local state."
assert_local_backend_restored "${version_field_fixture}"
record_negative_case "state-terraform-version-field-missing"

plan_fixture="$(make_fixture plan-failure)"
plan_error="${plan_fixture}/migration-error.txt"
if PATH="${plan_fixture}/bin:${PATH}" \
  FAKE_LOG="${plan_fixture}/commands.log" \
  FAKE_PLAN_EXIT_CODE=44 \
  "${plan_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${plan_error}"; then
  echo "Migration unexpectedly accepted a failed post-migration plan." >&2
  exit 1
fi
assert_expected_failure_output \
  "post-migration-plan-failure-restores-backend" \
  "${plan_error}" \
  "The post-migration plan could not complete."
grep -Eq '^arn:aws:iam::[0-9]{12}:role/opensearch-lab-terraform-admin\|.* plan ' \
  "${plan_fixture}/commands.log"
assert_local_backend_restored "${plan_fixture}"
record_negative_case "post-migration-plan-failure-restores-backend"

changed_plan_fixture="$(make_fixture plan-has-changes)"
changed_plan_error="${changed_plan_fixture}/migration-error.txt"
if PATH="${changed_plan_fixture}/bin:${PATH}" \
  FAKE_LOG="${changed_plan_fixture}/commands.log" \
  FAKE_PLAN_EXIT_CODE=2 \
  "${changed_plan_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${changed_plan_error}"; then
  echo "Migration unexpectedly accepted a post-migration plan with changes." >&2
  exit 1
fi
assert_expected_failure_output \
  "post-migration-plan-exit-two" \
  "${changed_plan_error}" \
  "The post-migration plan contains changes; migration verification failed."
assert_local_backend_restored "${changed_plan_fixture}"
record_negative_case "post-migration-plan-exit-two"

lock_fixture="$(make_fixture residual-lock)"
lock_error="${lock_fixture}/migration-error.txt"
if PATH="${lock_fixture}/bin:${PATH}" \
  FAKE_LOG="${lock_fixture}/commands.log" \
  FAKE_RESIDUAL_LOCK=true \
  "${lock_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${lock_error}"; then
  echo "Migration unexpectedly accepted a residual Terraform lock object." >&2
  exit 1
fi
assert_expected_failure_output \
  "post-migration-residual-lock" \
  "${lock_error}" \
  "The post-migration plan left a Terraform state lock object behind."
assert_local_backend_restored "${lock_fixture}"
record_negative_case "post-migration-residual-lock"

workspace_fixture="$(make_fixture workspace)"
workspace_error="${workspace_fixture}/migration-error.txt"
if PATH="${workspace_fixture}/bin:${PATH}" \
  FAKE_LOG="${workspace_fixture}/commands.log" \
  FAKE_WORKSPACE=non-default \
  "${workspace_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${workspace_error}"; then
  echo "Migration unexpectedly accepted a non-default workspace." >&2
  exit 1
fi
assert_expected_failure_output \
  "non-default-workspace" \
  "${workspace_error}" \
  "State migration requires default to be the only Terraform workspace."
assert_local_backend_restored "${workspace_fixture}"
record_negative_case "non-default-workspace"

extra_workspace_fixture="$(make_fixture extra-workspace)"
extra_workspace_error="${extra_workspace_fixture}/migration-error.txt"
if PATH="${extra_workspace_fixture}/bin:${PATH}" \
  FAKE_LOG="${extra_workspace_fixture}/commands.log" \
  FAKE_EXTRA_WORKSPACE=true \
  "${extra_workspace_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${extra_workspace_error}"; then
  echo "Migration unexpectedly accepted an inactive extra workspace." >&2
  exit 1
fi
assert_expected_failure_output \
  "additional-workspace" \
  "${extra_workspace_error}" \
  "State migration requires default to be the only Terraform workspace."
assert_local_backend_restored "${extra_workspace_fixture}"
record_negative_case "additional-workspace"

local_state_rollback_fixture="$(make_fixture local-state-rollback-error)"
local_state_rollback_error="${local_state_rollback_fixture}/rollback-error.txt"
if PATH="${local_state_rollback_fixture}/bin:${PATH}" \
  FAKE_LOG="${local_state_rollback_fixture}/commands.log" \
  FAKE_CORRUPT_LOCAL_STATE_RESTORE=true \
  FAKE_PLAN_EXIT_CODE=44 \
  "${local_state_rollback_fixture}/infra/bootstrap/scripts/migrate-state.sh" \
  --approved >/dev/null 2>"${local_state_rollback_error}"; then
  echo "Migration unexpectedly hid a local-state rollback verification failure." >&2
  exit 1
fi
assert_expected_failure_output \
  "local-state-rollback-mismatch-reported" \
  "${local_state_rollback_error}" \
  "Rollback restored local state which does not match the recovery copy."
grep -Fq 'Migration failed and rollback was incomplete (1 rollback errors).' \
  "${local_state_rollback_error}"
cmp -s "${local_state_rollback_fixture}/expected-backend.tf" \
  "${local_state_rollback_fixture}/infra/bootstrap/backend.tf"
cmp -s "${local_state_rollback_fixture}/expected-backend-cache.tfstate" \
  "${local_state_rollback_fixture}/infra/bootstrap/.terraform/terraform.tfstate"
local_state_recovery="$(
  find "${local_state_rollback_fixture}/.private/terraform-bootstrap" \
    -name 'pre-migration-*.tfstate' \
    ! -name 'pre-migration-backend-cache-*' \
    -print -quit
)"
if jq -e -s '
  .[0].lineage == .[1].lineage
  and .[0].serial == .[1].serial
  and (.[0] | del(.terraform_version)) == (.[1] | del(.terraform_version))
' "${local_state_recovery}" \
  "${local_state_rollback_fixture}/.private/terraform-bootstrap/terraform.tfstate" >/dev/null; then
  echo "Local-state rollback corruption was not present after the negative case." >&2
  exit 1
fi
assert_mode_600 \
  "${local_state_rollback_fixture}/.private/terraform-bootstrap/terraform.tfstate"
record_negative_case "local-state-rollback-mismatch-reported"

backend_rollback_fixture="$(make_fixture backend-rollback-error)"
backend_rollback_error="${backend_rollback_fixture}/rollback-error.txt"
if PATH="${backend_rollback_fixture}/bin:${PATH}" \
  FAKE_LOG="${backend_rollback_fixture}/commands.log" \
  FAKE_DELETE_BACKEND_RECOVERY=true \
  FAKE_PLAN_EXIT_CODE=44 \
  "${backend_rollback_fixture}/infra/bootstrap/scripts/migrate-state.sh" \
  --approved >/dev/null 2>"${backend_rollback_error}"; then
  echo "Migration unexpectedly hid a backend-file rollback failure." >&2
  exit 1
fi
assert_expected_failure_output \
  "backend-file-rollback-error-reported" \
  "${backend_rollback_error}" \
  "Rollback could not restore backend.tf."
grep -Fq 'Migration failed and rollback was incomplete (1 rollback errors).' \
  "${backend_rollback_error}"
cmp -s "${backend_rollback_fixture}/expected-backend-cache.tfstate" \
  "${backend_rollback_fixture}/infra/bootstrap/.terraform/terraform.tfstate"
record_negative_case "backend-file-rollback-error-reported"

cache_rollback_fixture="$(make_fixture cache-rollback-error)"
cache_rollback_error="${cache_rollback_fixture}/rollback-error.txt"
if PATH="${cache_rollback_fixture}/bin:${PATH}" \
  FAKE_LOG="${cache_rollback_fixture}/commands.log" \
  FAKE_DELETE_CACHE_RECOVERY=true \
  FAKE_PLAN_EXIT_CODE=44 \
  "${cache_rollback_fixture}/infra/bootstrap/scripts/migrate-state.sh" \
  --approved >/dev/null 2>"${cache_rollback_error}"; then
  echo "Migration unexpectedly hid a backend-cache rollback failure." >&2
  exit 1
fi
assert_expected_failure_output \
  "backend-cache-rollback-error-reported" \
  "${cache_rollback_error}" \
  "Rollback could not restore Terraform's cached backend metadata."
grep -Fq 'Migration failed and rollback was incomplete (1 rollback errors).' \
  "${cache_rollback_error}"
cmp -s "${cache_rollback_fixture}/expected-backend.tf" \
  "${cache_rollback_fixture}/infra/bootstrap/backend.tf"
record_negative_case "backend-cache-rollback-error-reported"

printf 'State migration safeguards passed (%d negative cases).\n' "${negative_case_count}"
