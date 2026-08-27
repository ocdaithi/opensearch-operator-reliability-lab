#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
background_pid=""
negative_case_count=0

cleanup() {
  local exit_status=$?

  trap - EXIT
  if [[ -n "${background_pid}" ]]; then
    kill "${background_pid}" >/dev/null 2>&1 || true
    wait "${background_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf -- "${test_root}"
  exit "${exit_status}"
}
trap cleanup EXIT

record_negative_case() {
  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: %s\n' "$1"
}

make_fixture() {
  local fixture_name="$1"
  local fixture_root="${test_root}/${fixture_name}"

  mkdir -p \
    "${fixture_root}/bin" \
    "${fixture_root}/infra/bootstrap/.terraform" \
    "${fixture_root}/infra/bootstrap/scripts" \
    "${fixture_root}/.private/terraform-bootstrap" \
    "${fixture_root}/remote-store/bootstrap"
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
    "${fixture_root}/expected-backend-cache.tfstate" \
    "${fixture_root}/expected-local-state.tfstate" \
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
remote_state="${fixture_root}/remote-store/bootstrap/terraform.tfstate"
remote_lock="${fixture_root}/remote-store/bootstrap/terraform.tfstate.tflock"
migration_attempted="${fixture_root}/migration-attempted"

case "$*" in
  *" init -migrate-state "*)
    printf '%s\n' '{"backend":{"type":"s3"},"fixture":"remote-cache"}' >"${backend_cache}"
    : >"${migration_attempted}"

    case "${FAKE_MIGRATION_FAILURE:-none}" in
      before-write)
        exit 42
        ;;
      after-lock)
        : >"${remote_lock}"
        exit 42
        ;;
      after-state)
        /bin/cp "${local_state}" "${remote_state}"
        rm -f -- "${local_state}"
        exit 42
        ;;
      interrupt-before-write)
        kill -TERM "${PPID}"
        exit 143
        ;;
      none)
        /bin/cp "${local_state}" "${remote_state}"
        rm -f -- "${local_state}"
        ;;
      *)
        printf 'Unknown fake migration failure mode: %s\n' \
          "${FAKE_MIGRATION_FAILURE}" >&2
        exit 96
        ;;
    esac
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
      if [[ -n "${FAKE_HOLD_READY_FILE:-}" ]]; then
        : >"${FAKE_HOLD_READY_FILE}"
        while [[ ! -e "${FAKE_HOLD_RELEASE_FILE}" ]]; do
          sleep 0.05
        done
      fi
      if [[ "${FAKE_REMOTE_PULL_FAILURE:-false}" == "true" ]]; then
        exit 46
      fi
      if [[ ! -s "${remote_state}" ]]; then
        exit 47
      fi
      case "${FAKE_STATE_VERIFICATION:-valid}" in
        lineage-mismatch)
          jq -c '.terraform_version = "1.16.0" | .lineage = "unexpected-lineage"' \
            "${remote_state}"
          ;;
        serial-regression)
          jq -c '.terraform_version = "1.16.0" | .serial = 3' "${remote_state}"
          ;;
        serial-advance)
          jq -c '.terraform_version = "1.16.0" | .serial = 5' "${remote_state}"
          ;;
        semantic-mismatch)
          jq -c '.terraform_version = "1.16.0" | .outputs.fixture.value = "changed"' \
            "${remote_state}"
          ;;
        terraform-version-missing)
          jq -c 'del(.terraform_version)' "${remote_state}"
          ;;
        *)
          jq -c '.terraform_version = "1.16.0"' "${remote_state}"
          ;;
      esac
    elif [[ "${FAKE_STATE_VERIFICATION:-valid}" == "local-recovery-mismatch" ]]; then
      jq -c '.terraform_version = "1.16.0" | .outputs.fixture.value = "changed"' \
        "${local_state}"
    else
      jq -c '.terraform_version = "1.16.0"' "${local_state}"
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
    : >"${remote_lock}"
    if [[ "${FAKE_RESIDUAL_LOCK:-false}" != "true" ]]; then
      rm -f -- "${remote_lock}"
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
fixture_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
object_key=""

while (($# > 0)); do
  case "$1" in
    --prefix)
      shift
      object_key="${1:-}"
      ;;
  esac
  shift || true
done

if [[ -z "${object_key}" ]]; then
  printf 'Unexpected fake AWS command without an exact prefix.\n' >&2
  exit 98
fi

if [[ -e "${fixture_root}/migration-attempted" &&
  "${FAKE_POST_INIT_QUERY_FAILURE:-none}" == "${object_key}" ]]; then
  exit 63
fi
if [[ "${FAKE_QUERY_FAILURE:-none}" == "${object_key}" ]]; then
  exit 64
fi

case "${object_key}" in
  bootstrap/terraform.tfstate)
    object_file="${fixture_root}/remote-store/bootstrap/terraform.tfstate"
    ;;
  bootstrap/terraform.tfstate.tflock)
    object_file="${fixture_root}/remote-store/bootstrap/terraform.tfstate.tflock"
    ;;
  *)
    printf 'Unexpected fake AWS object key: %s\n' "${object_key}" >&2
    exit 98
    ;;
esac

if [[ -e "${object_file}" ]]; then
  jq -cn --arg object_key "${object_key}" \
    '{IsTruncated:false,KeyCount:1,Contents:[{Key:$object_key}]}'
else
  printf '%s\n' '{"IsTruncated":false,"KeyCount":0,"Contents":[]}'
fi
EOF

  cat >"${fixture_root}/bin/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

arguments=("$@")
destination="${arguments[${#arguments[@]} - 1]}"
if [[ "${FAKE_FAIL_CACHE_RECOVERY_COPY:-false}" == "true" &&
  "${destination}" == */pre-migration-backend-cache-*.tfstate ]]; then
  exit 67
fi

/bin/cp "$@"

if [[ "${FAKE_CORRUPT_LOCAL_STATE_RESTORE:-false}" == "true" &&
  "${destination}" == */terraform.tfstate.rollback.* ]]; then
  corrupt_state="${destination}.corrupt"
  jq -c '.outputs.fixture.value = "rollback-corrupted"' \
    "${destination}" >"${corrupt_state}"
  chmod 600 "${corrupt_state}"
  /bin/mv "${corrupt_state}" "${destination}"
fi
EOF

  cat >"${fixture_root}/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

arguments=("$@")
destination="${arguments[${#arguments[@]} - 1]}"
if [[ "${FAKE_FAIL_BACKEND_MOVE:-false}" == "true" &&
  "${destination}" == */infra/bootstrap/backend.tf ]]; then
  exit 65
fi
/bin/mv "$@"
EOF

  cat >"${fixture_root}/bin/chmod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

arguments=("$@")
destination="${arguments[${#arguments[@]} - 1]}"
if [[ "${FAKE_FAIL_S3_BACKEND_CHMOD:-false}" == "true" &&
  "${destination}" == */infra/bootstrap/backend.tf &&
  -f "${destination}" ]] && grep -Fq 'backend "s3"' "${destination}"; then
  exit 66
fi
/bin/chmod "$@"
EOF

  chmod 700 \
    "${fixture_root}/bin/terraform" \
    "${fixture_root}/bin/aws" \
    "${fixture_root}/bin/cp" \
    "${fixture_root}/bin/mv" \
    "${fixture_root}/bin/chmod"
  printf '%s\n' "${fixture_root}"
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

file_mode() {
  local file="$1"

  if stat -f '%Lp' "${file}" >/dev/null 2>&1; then
    stat -f '%Lp' "${file}"
  else
    stat -c '%a' "${file}"
  fi
}

recovery_state_file() {
  local fixture_root="$1"

  find "${fixture_root}/.private/terraform-bootstrap" -type f \
    -name 'pre-migration-*.tfstate' \
    ! -name 'pre-migration-backend-cache-*' \
    -print -quit
}

assert_recovery_retained() {
  local fixture_root="$1"
  local recovery_file

  recovery_file="$(recovery_state_file "${fixture_root}")"
  test -n "${recovery_file}"
  cmp -s "${fixture_root}/expected-local-state.tfstate" "${recovery_file}"
  assert_mode_600 "${recovery_file}"
}

assert_invocation_lock_released() {
  local fixture_root="$1"

  test ! -e "${fixture_root}/.private/terraform-bootstrap/.migrate-state.lock"
}

assert_local_backend_restored() {
  local fixture_root="$1"

  cmp -s "${fixture_root}/expected-backend.tf" \
    "${fixture_root}/infra/bootstrap/backend.tf"
  cmp -s "${fixture_root}/expected-backend-cache.tfstate" \
    "${fixture_root}/infra/bootstrap/.terraform/terraform.tfstate"
  cmp -s "${fixture_root}/expected-local-state.tfstate" \
    "${fixture_root}/.private/terraform-bootstrap/terraform.tfstate"
  test "$(file_mode "${fixture_root}/expected-backend.tf")" = \
    "$(file_mode "${fixture_root}/infra/bootstrap/backend.tf")"
  test "$(file_mode "${fixture_root}/expected-backend-cache.tfstate")" = \
    "$(file_mode "${fixture_root}/infra/bootstrap/.terraform/terraform.tfstate")"
  test "$(file_mode "${fixture_root}/expected-local-state.tfstate")" = \
    "$(file_mode "${fixture_root}/.private/terraform-bootstrap/terraform.tfstate")"
  assert_invocation_lock_released "${fixture_root}"
}

assert_s3_backend_preserved() {
  local fixture_root="$1"

  grep -Fq 'backend "s3"' "${fixture_root}/infra/bootstrap/backend.tf"
  grep -Fq '"fixture":"remote-cache"' \
    "${fixture_root}/infra/bootstrap/.terraform/terraform.tfstate"
  assert_mode_600 "${fixture_root}/infra/bootstrap/backend.tf"
  assert_mode_600 "${fixture_root}/infra/bootstrap/.terraform/terraform.tfstate"
  assert_recovery_retained "${fixture_root}"
  assert_invocation_lock_released "${fixture_root}"
}

assert_remote_authoritative() {
  local fixture_root="$1"

  assert_s3_backend_preserved "${fixture_root}"
  cmp -s "${fixture_root}/expected-local-state.tfstate" \
    "${fixture_root}/remote-store/bootstrap/terraform.tfstate"
  test ! -e "${fixture_root}/.private/terraform-bootstrap/terraform.tfstate"
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
    'Unexpected fake (AWS|Terraform)|Required command is unavailable:|command not found|unbound variable' \
    "${output_file}"; then
    printf 'Negative case %s encountered an unrelated fixture failure.\n' \
      "${case_name}" >&2
    cat "${output_file}" >&2
    exit 1
  fi
}

assert_committed_failure() {
  local case_name="$1"
  local fixture_root="$2"
  local output_file="$3"
  local expected_diagnostic="$4"

  assert_expected_failure_output "${case_name}" "${output_file}" "${expected_diagnostic}"
  assert_expected_failure_output \
    "${case_name}" \
    "${output_file}" \
    "Migration committed to S3, but subsequent verification failed."
  assert_remote_authoritative "${fixture_root}"
}

success_fixture="$(make_fixture success)"
success_log="${success_fixture}/commands.log"
PATH="${success_fixture}/bin:${PATH}" FAKE_LOG="${success_log}" \
  "${success_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved >/dev/null

assert_remote_authoritative "${success_fixture}"
grep -Fq 'assume_role = {' "${success_fixture}/infra/bootstrap/backend.tf"
grep -Fq 'profile      = "opensearch-lab-terraform"' \
  "${success_fixture}/infra/bootstrap/backend.tf"
grep -Eq '^arn:aws:iam::[0-9]{12}:role/opensearch-lab-terraform-admin\|.* plan ' \
  "${success_log}"
grep -Fq -- '-detailed-exitcode' "${success_log}"
grep -Fq -- '--prefix bootstrap/terraform.tfstate --output json' "${success_log}"
grep -Fq -- '--prefix bootstrap/terraform.tfstate.tflock --output json' "${success_log}"

approval_fixture="$(make_fixture approval)"
approval_error="${approval_fixture}/migration-error.txt"
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

prewrite_fixture="$(make_fixture pre-write-failure)"
prewrite_error="${prewrite_fixture}/migration-error.txt"
if PATH="${prewrite_fixture}/bin:${PATH}" \
  FAKE_LOG="${prewrite_fixture}/commands.log" \
  FAKE_EXTRA_WORKSPACE=true \
  "${prewrite_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${prewrite_error}"; then
  echo "Migration unexpectedly accepted an additional workspace." >&2
  exit 1
fi
assert_expected_failure_output \
  "pre-write-failure-restores-local-operation" \
  "${prewrite_error}" \
  "State migration requires default to be the only Terraform workspace."
assert_expected_failure_output \
  "pre-write-failure-restores-local-operation" \
  "${prewrite_error}" \
  "the original local backend, cached metadata and state were restored and verified."
assert_local_backend_restored "${prewrite_fixture}"
test ! -e "${prewrite_fixture}/remote-store/bootstrap/terraform.tfstate"
record_negative_case "pre-write-failure-restores-local-operation"

cache_copy_fixture="$(make_fixture cache-recovery-copy-failure)"
cache_copy_error="${cache_copy_fixture}/migration-error.txt"
if PATH="${cache_copy_fixture}/bin:${PATH}" \
  FAKE_LOG="${cache_copy_fixture}/commands.log" \
  FAKE_FAIL_CACHE_RECOVERY_COPY=true \
  "${cache_copy_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${cache_copy_error}"; then
  echo "Migration unexpectedly continued after the cache recovery copy failed." >&2
  exit 1
fi
assert_expected_failure_output \
  "cache-recovery-copy-failure-preserves-original" \
  "${cache_copy_error}" \
  "Migration failed before remote state was written"
assert_local_backend_restored "${cache_copy_fixture}"
if [[ -e "${cache_copy_fixture}/commands.log" ]] &&
  grep -Fq ' init -reconfigure ' "${cache_copy_fixture}/commands.log"; then
  echo "Terraform init ran after the cache recovery copy failed." >&2
  exit 1
fi
record_negative_case "cache-recovery-copy-failure-preserves-original"

move_failure_fixture="$(make_fixture backend-move-failure)"
move_failure_error="${move_failure_fixture}/migration-error.txt"
if PATH="${move_failure_fixture}/bin:${PATH}" \
  FAKE_LOG="${move_failure_fixture}/commands.log" \
  FAKE_FAIL_BACKEND_MOVE=true \
  "${move_failure_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${move_failure_error}"; then
  echo "Migration unexpectedly continued after backend replacement failed." >&2
  exit 1
fi
assert_expected_failure_output \
  "backend-move-failure-is-pre-write" \
  "${move_failure_error}" \
  "Migration failed before remote state was written"
assert_local_backend_restored "${move_failure_fixture}"
if grep -Fq ' init -migrate-state ' "${move_failure_fixture}/commands.log"; then
  echo "Migration init ran after backend replacement failed." >&2
  exit 1
fi
record_negative_case "backend-move-failure-is-pre-write"

chmod_failure_fixture="$(make_fixture backend-chmod-failure)"
chmod_failure_error="${chmod_failure_fixture}/migration-error.txt"
if PATH="${chmod_failure_fixture}/bin:${PATH}" \
  FAKE_LOG="${chmod_failure_fixture}/commands.log" \
  FAKE_FAIL_S3_BACKEND_CHMOD=true \
  "${chmod_failure_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${chmod_failure_error}"; then
  echo "Migration unexpectedly continued after securing backend.tf failed." >&2
  exit 1
fi
assert_expected_failure_output \
  "backend-chmod-failure-is-pre-write" \
  "${chmod_failure_error}" \
  "Migration failed before remote state was written"
assert_local_backend_restored "${chmod_failure_fixture}"
if grep -Fq ' init -migrate-state ' "${chmod_failure_fixture}/commands.log"; then
  echo "Migration init ran after securing backend.tf failed." >&2
  exit 1
fi
record_negative_case "backend-chmod-failure-is-pre-write"

absent_cache_fixture="$(make_fixture absent-cache-restoration)"
absent_cache_error="${absent_cache_fixture}/migration-error.txt"
rm -f -- "${absent_cache_fixture}/infra/bootstrap/.terraform/terraform.tfstate"
if PATH="${absent_cache_fixture}/bin:${PATH}" \
  FAKE_LOG="${absent_cache_fixture}/commands.log" \
  FAKE_EXTRA_WORKSPACE=true \
  "${absent_cache_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${absent_cache_error}"; then
  echo "Migration unexpectedly accepted an additional workspace." >&2
  exit 1
fi
assert_expected_failure_output \
  "absent-backend-cache-is-restored-exactly" \
  "${absent_cache_error}" \
  "Migration failed before remote state was written"
cmp -s "${absent_cache_fixture}/expected-backend.tf" \
  "${absent_cache_fixture}/infra/bootstrap/backend.tf"
cmp -s "${absent_cache_fixture}/expected-local-state.tfstate" \
  "${absent_cache_fixture}/.private/terraform-bootstrap/terraform.tfstate"
test ! -e "${absent_cache_fixture}/infra/bootstrap/.terraform/terraform.tfstate"
assert_invocation_lock_released "${absent_cache_fixture}"
record_negative_case "absent-backend-cache-is-restored-exactly"

local_mismatch_fixture="$(make_fixture local-recovery-mismatch)"
local_mismatch_error="${local_mismatch_fixture}/migration-error.txt"
if PATH="${local_mismatch_fixture}/bin:${PATH}" \
  FAKE_LOG="${local_mismatch_fixture}/commands.log" \
  FAKE_STATE_VERIFICATION=local-recovery-mismatch \
  "${local_mismatch_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${local_mismatch_error}"; then
  echo "Migration unexpectedly accepted a mismatched local state pull." >&2
  exit 1
fi
assert_expected_failure_output \
  "local-state-recovery-mismatch" \
  "${local_mismatch_error}" \
  "The original local state does not match its exact recovery copy and pulled snapshot."
assert_local_backend_restored "${local_mismatch_fixture}"
record_negative_case "local-state-recovery-mismatch"

precheck_unknown_fixture="$(make_fixture destination-check-unknown)"
precheck_unknown_error="${precheck_unknown_fixture}/migration-error.txt"
if PATH="${precheck_unknown_fixture}/bin:${PATH}" \
  FAKE_LOG="${precheck_unknown_fixture}/commands.log" \
  FAKE_QUERY_FAILURE=bootstrap/terraform.tfstate \
  "${precheck_unknown_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${precheck_unknown_error}"; then
  echo "Migration unexpectedly accepted an unverified empty destination." >&2
  exit 1
fi
assert_expected_failure_output \
  "destination-absence-unknown" \
  "${precheck_unknown_error}" \
  "The remote state destination could not be proven empty; no migration was attempted."
assert_local_backend_restored "${precheck_unknown_fixture}"
record_negative_case "destination-absence-unknown"

init_empty_fixture="$(make_fixture init-failure-empty)"
init_empty_error="${init_empty_fixture}/migration-error.txt"
if PATH="${init_empty_fixture}/bin:${PATH}" \
  FAKE_LOG="${init_empty_fixture}/commands.log" \
  FAKE_MIGRATION_FAILURE=before-write \
  "${init_empty_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${init_empty_error}"; then
  echo "Migration unexpectedly accepted a failed init." >&2
  exit 1
fi
assert_expected_failure_output \
  "init-failure-with-empty-remote-rolls-back" \
  "${init_empty_error}" \
  "both exact remote keys are absent; safe rollback is permitted."
assert_local_backend_restored "${init_empty_fixture}"
test ! -e "${init_empty_fixture}/remote-store/bootstrap/terraform.tfstate"
test "$(grep -Fc -- '--prefix bootstrap/terraform.tfstate --output json' \
  "${init_empty_fixture}/commands.log")" -eq 2
test "$(grep -Fc -- '--prefix bootstrap/terraform.tfstate.tflock --output json' \
  "${init_empty_fixture}/commands.log")" -eq 2
record_negative_case "init-failure-with-empty-remote-rolls-back"

init_state_fixture="$(make_fixture init-failure-with-state)"
init_state_error="${init_state_fixture}/migration-error.txt"
if PATH="${init_state_fixture}/bin:${PATH}" \
  FAKE_LOG="${init_state_fixture}/commands.log" \
  FAKE_MIGRATION_FAILURE=after-state \
  "${init_state_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${init_state_error}"; then
  echo "Migration unexpectedly rolled through a partially committed init." >&2
  exit 1
fi
assert_expected_failure_output \
  "init-failure-with-remote-state-fails-closed" \
  "${init_state_error}" \
  "The migration may be partially committed"
assert_remote_authoritative "${init_state_fixture}"
record_negative_case "init-failure-with-remote-state-fails-closed"

init_lock_fixture="$(make_fixture init-failure-with-lock)"
init_lock_error="${init_lock_fixture}/migration-error.txt"
if PATH="${init_lock_fixture}/bin:${PATH}" \
  FAKE_LOG="${init_lock_fixture}/commands.log" \
  FAKE_MIGRATION_FAILURE=after-lock \
  "${init_lock_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${init_lock_error}"; then
  echo "Migration unexpectedly rolled back after observing a remote lock." >&2
  exit 1
fi
assert_expected_failure_output \
  "init-failure-with-remote-lock-fails-closed" \
  "${init_lock_error}" \
  "The migration may be partially committed"
assert_s3_backend_preserved "${init_lock_fixture}"
cmp -s "${init_lock_fixture}/expected-local-state.tfstate" \
  "${init_lock_fixture}/.private/terraform-bootstrap/terraform.tfstate"
test -e "${init_lock_fixture}/remote-store/bootstrap/terraform.tfstate.tflock"
record_negative_case "init-failure-with-remote-lock-fails-closed"

init_unknown_fixture="$(make_fixture init-failure-unknown)"
init_unknown_error="${init_unknown_fixture}/migration-error.txt"
if PATH="${init_unknown_fixture}/bin:${PATH}" \
  FAKE_LOG="${init_unknown_fixture}/commands.log" \
  FAKE_MIGRATION_FAILURE=before-write \
  FAKE_POST_INIT_QUERY_FAILURE=bootstrap/terraform.tfstate \
  "${init_unknown_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${init_unknown_error}"; then
  echo "Migration unexpectedly rolled back with unknown remote status." >&2
  exit 1
fi
assert_expected_failure_output \
  "init-failure-with-unknown-remote-status-fails-closed" \
  "${init_unknown_error}" \
  "The migration status is indeterminate"
assert_s3_backend_preserved "${init_unknown_fixture}"
cmp -s "${init_unknown_fixture}/expected-local-state.tfstate" \
  "${init_unknown_fixture}/.private/terraform-bootstrap/terraform.tfstate"
record_negative_case "init-failure-with-unknown-remote-status-fails-closed"

interrupted_init_fixture="$(make_fixture interrupted-init)"
interrupted_init_error="${interrupted_init_fixture}/migration-error.txt"
if PATH="${interrupted_init_fixture}/bin:${PATH}" \
  FAKE_LOG="${interrupted_init_fixture}/commands.log" \
  FAKE_MIGRATION_FAILURE=interrupt-before-write \
  "${interrupted_init_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${interrupted_init_error}"; then
  echo "Migration unexpectedly rolled back after init was interrupted." >&2
  exit 1
fi
assert_expected_failure_output \
  "interruption-after-init-starts-fails-closed" \
  "${interrupted_init_error}" \
  "Terraform migration was interrupted after init started. The migration status is indeterminate"
assert_s3_backend_preserved "${interrupted_init_fixture}"
cmp -s "${interrupted_init_fixture}/expected-local-state.tfstate" \
  "${interrupted_init_fixture}/.private/terraform-bootstrap/terraform.tfstate"
test "$(grep -Fc -- '--prefix bootstrap/terraform.tfstate --output json' \
  "${interrupted_init_fixture}/commands.log")" -eq 2
test "$(grep -Fc -- '--prefix bootstrap/terraform.tfstate.tflock --output json' \
  "${interrupted_init_fixture}/commands.log")" -eq 2
record_negative_case "interruption-after-init-starts-fails-closed"

remote_pull_fixture="$(make_fixture remote-pull-failure)"
remote_pull_error="${remote_pull_fixture}/migration-error.txt"
if PATH="${remote_pull_fixture}/bin:${PATH}" \
  FAKE_LOG="${remote_pull_fixture}/commands.log" \
  FAKE_REMOTE_PULL_FAILURE=true \
  "${remote_pull_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${remote_pull_error}"; then
  echo "Migration unexpectedly accepted a failed remote state pull." >&2
  exit 1
fi
assert_committed_failure \
  "remote-pull-failure-keeps-s3-authoritative" \
  "${remote_pull_fixture}" \
  "${remote_pull_error}" \
  "Remote state could not be pulled after migration committed."
record_negative_case "remote-pull-failure-keeps-s3-authoritative"

for mismatch in lineage-mismatch serial-regression serial-advance semantic-mismatch terraform-version-missing; do
  mismatch_fixture="$(make_fixture "state-${mismatch}")"
  mismatch_error="${mismatch_fixture}/migration-error.txt"
  if PATH="${mismatch_fixture}/bin:${PATH}" \
    FAKE_LOG="${mismatch_fixture}/commands.log" \
    FAKE_STATE_VERIFICATION="${mismatch}" \
    "${mismatch_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
    >/dev/null 2>"${mismatch_error}"; then
    printf 'Migration unexpectedly accepted remote state mismatch: %s.\n' \
      "${mismatch}" >&2
    exit 1
  fi
  assert_committed_failure \
    "state-${mismatch}-keeps-s3-authoritative" \
    "${mismatch_fixture}" \
    "${mismatch_error}" \
    "Remote state differs from the recovered local state."
  record_negative_case "state-${mismatch}-keeps-s3-authoritative"
done

for plan_exit in 1 2; do
  plan_fixture="$(make_fixture "plan-exit-${plan_exit}")"
  plan_error="${plan_fixture}/migration-error.txt"
  if PATH="${plan_fixture}/bin:${PATH}" \
    FAKE_LOG="${plan_fixture}/commands.log" \
    FAKE_PLAN_EXIT_CODE="${plan_exit}" \
    "${plan_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
    >/dev/null 2>"${plan_error}"; then
    printf 'Migration unexpectedly accepted plan exit %s.\n' "${plan_exit}" >&2
    exit 1
  fi
  if [[ "${plan_exit}" == "2" ]]; then
    plan_diagnostic="The post-migration plan contains changes; migration verification failed."
  else
    plan_diagnostic="The post-migration plan could not complete."
  fi
  assert_committed_failure \
    "plan-exit-${plan_exit}-keeps-s3-authoritative" \
    "${plan_fixture}" \
    "${plan_error}" \
    "${plan_diagnostic}"
  record_negative_case "plan-exit-${plan_exit}-keeps-s3-authoritative"
done

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
assert_committed_failure \
  "residual-lock-keeps-s3-authoritative" \
  "${lock_fixture}" \
  "${lock_error}" \
  "The post-migration plan left a Terraform state lock object behind."
test -e "${lock_fixture}/remote-store/bootstrap/terraform.tfstate.tflock"
record_negative_case "residual-lock-keeps-s3-authoritative"

concurrent_fixture="$(make_fixture concurrent)"
concurrent_ready="${concurrent_fixture}/first-invocation-ready"
concurrent_release="${concurrent_fixture}/release-first-invocation"
concurrent_first_error="${concurrent_fixture}/first-error.txt"
PATH="${concurrent_fixture}/bin:${PATH}" \
  FAKE_LOG="${concurrent_fixture}/commands.log" \
  FAKE_HOLD_READY_FILE="${concurrent_ready}" \
  FAKE_HOLD_RELEASE_FILE="${concurrent_release}" \
  "${concurrent_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${concurrent_first_error}" &
background_pid=$!

for _ in {1..200}; do
  if [[ -e "${concurrent_ready}" ]]; then
    break
  fi
  sleep 0.05
done
if [[ ! -e "${concurrent_ready}" ]]; then
  echo "The first migration invocation did not reach the concurrency hold point." >&2
  exit 1
fi

concurrent_second_error="${concurrent_fixture}/second-error.txt"
if PATH="${concurrent_fixture}/bin:${PATH}" \
  FAKE_LOG="${concurrent_fixture}/commands.log" \
  "${concurrent_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${concurrent_second_error}"; then
  echo "A concurrent migration invocation unexpectedly ran." >&2
  exit 1
fi
assert_expected_failure_output \
  "concurrent-invocation-rejected" \
  "${concurrent_second_error}" \
  "Another state migration invocation is already in progress."
: >"${concurrent_release}"
if ! wait "${background_pid}"; then
  background_pid=""
  echo "The first migration invocation failed after the concurrency check." >&2
  cat "${concurrent_first_error}" >&2
  exit 1
fi
background_pid=""
assert_remote_authoritative "${concurrent_fixture}"
test "$(grep -Fc ' init -migrate-state ' "${concurrent_fixture}/commands.log")" -eq 1
record_negative_case "concurrent-invocation-rejected"

second_attempt_fixture="$(make_fixture second-attempt)"
second_attempt_log="${second_attempt_fixture}/commands.log"
PATH="${second_attempt_fixture}/bin:${PATH}" FAKE_LOG="${second_attempt_log}" \
  "${second_attempt_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved >/dev/null
cp "${second_attempt_fixture}/remote-store/bootstrap/terraform.tfstate" \
  "${second_attempt_fixture}/remote-state-after-first-attempt.tfstate"
cp "${second_attempt_fixture}/expected-backend.tf" \
  "${second_attempt_fixture}/infra/bootstrap/backend.tf"
cp "${second_attempt_fixture}/expected-backend-cache.tfstate" \
  "${second_attempt_fixture}/infra/bootstrap/.terraform/terraform.tfstate"
cp "${second_attempt_fixture}/expected-local-state.tfstate" \
  "${second_attempt_fixture}/.private/terraform-bootstrap/terraform.tfstate"
chmod "$(file_mode "${second_attempt_fixture}/expected-backend.tf")" \
  "${second_attempt_fixture}/infra/bootstrap/backend.tf"
chmod 600 \
  "${second_attempt_fixture}/infra/bootstrap/.terraform/terraform.tfstate" \
  "${second_attempt_fixture}/.private/terraform-bootstrap/terraform.tfstate"

second_attempt_error="${second_attempt_fixture}/migration-error.txt"
if PATH="${second_attempt_fixture}/bin:${PATH}" FAKE_LOG="${second_attempt_log}" \
  "${second_attempt_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${second_attempt_error}"; then
  echo "A second migration attempt unexpectedly overwrote remote state." >&2
  exit 1
fi
assert_expected_failure_output \
  "second-attempt-rejects-occupied-destination" \
  "${second_attempt_error}" \
  "The remote state destination is not empty; no migration was attempted."
assert_local_backend_restored "${second_attempt_fixture}"
cmp -s "${second_attempt_fixture}/remote-state-after-first-attempt.tfstate" \
  "${second_attempt_fixture}/remote-store/bootstrap/terraform.tfstate"
test "$(grep -Fc ' init -migrate-state ' "${second_attempt_log}")" -eq 1
record_negative_case "second-attempt-rejects-occupied-destination"

rollback_verification_fixture="$(make_fixture rollback-verification)"
rollback_verification_error="${rollback_verification_fixture}/migration-error.txt"
if PATH="${rollback_verification_fixture}/bin:${PATH}" \
  FAKE_LOG="${rollback_verification_fixture}/commands.log" \
  FAKE_EXTRA_WORKSPACE=true \
  FAKE_CORRUPT_LOCAL_STATE_RESTORE=true \
  "${rollback_verification_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved \
  >/dev/null 2>"${rollback_verification_error}"; then
  echo "Migration unexpectedly hid a local-state rollback mismatch." >&2
  exit 1
fi
assert_expected_failure_output \
  "exact-local-state-rollback-is-verified" \
  "${rollback_verification_error}" \
  "Rollback restored local state which does not exactly match the recovery copy."
assert_expected_failure_output \
  "exact-local-state-rollback-is-verified" \
  "${rollback_verification_error}" \
  "Migration failed before commit and rollback was incomplete (1 rollback errors)."
cmp -s "${rollback_verification_fixture}/expected-backend.tf" \
  "${rollback_verification_fixture}/infra/bootstrap/backend.tf"
cmp -s "${rollback_verification_fixture}/expected-backend-cache.tfstate" \
  "${rollback_verification_fixture}/infra/bootstrap/.terraform/terraform.tfstate"
assert_invocation_lock_released "${rollback_verification_fixture}"
record_negative_case "exact-local-state-rollback-is-verified"

printf 'State migration state-machine safeguards passed (%d negative cases).\n' \
  "${negative_case_count}"
