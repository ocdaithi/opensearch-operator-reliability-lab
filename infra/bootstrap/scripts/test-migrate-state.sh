#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT

make_fixture() {
  fixture_name="$1"
  fixture_root="${test_root}/${fixture_name}"

  mkdir -p \
    "${fixture_root}/bin" \
    "${fixture_root}/infra/bootstrap/scripts" \
    "${fixture_root}/.private/terraform-bootstrap"
  git -C "${fixture_root}" init -q
  cp "${source_root}/infra/bootstrap/scripts/migrate-state.sh" \
    "${fixture_root}/infra/bootstrap/scripts/migrate-state.sh"
  cp "${source_root}/infra/bootstrap/backend.local.tf.example" \
    "${fixture_root}/infra/bootstrap/backend.tf"
  cp "${source_root}/infra/bootstrap/backend.local.tf.example" \
    "${fixture_root}/infra/bootstrap/backend.local.tf.example"
  printf 'budget_notification_email = "private@example.com"\n' \
    >"${fixture_root}/.private/terraform-bootstrap/terraform.tfvars"

  cat >"${fixture_root}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s|%s\n' "${TF_VAR_terraform_admin_role_arn:-unset}" "$*" >>"${FAKE_LOG}"

if [[ "${AWS_PROFILE:-}" != "opensearch-lab-terraform" ]]; then
  exit 43
fi

case "$*" in
  *" init -migrate-state "*)
    if [[ "${FAKE_MIGRATION_FAILURE:-false}" == "true" ]]; then
      exit 42
    fi
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
    printf '{"lineage":"fixture-lineage","serial":4}\n'
    ;;
  *" output -raw state_bucket_name")
    printf 'opensearch-lab-tfstate-fixture\n'
    ;;
  *" output -raw terraform_admin_role_arn")
    account_id="$(printf '%06d%06d' 123 456)"
    printf 'arn:aws:iam::%s:role/opensearch-lab-terraform-admin\n' "${account_id}"
    ;;
esac
EOF

  cat >"${fixture_root}/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'unset|%s\n' "$*" >>"${FAKE_LOG}"
if [[ "${FAKE_REMOTE_STATE:-empty}" == "present" ]]; then
  printf '{"Contents":[{"Key":"bootstrap/terraform.tfstate"}]}\n'
else
  printf '{"Contents":[]}\n'
fi
EOF

  chmod 700 "${fixture_root}/bin/terraform" "${fixture_root}/bin/aws"
  printf '%s\n' "${fixture_root}"
}

success_fixture="$(make_fixture success)"
success_log="${success_fixture}/commands.log"
PATH="${success_fixture}/bin:${PATH}" FAKE_LOG="${success_log}" \
  "${success_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved >/dev/null

grep -Fq 'assume_role = {' "${success_fixture}/infra/bootstrap/backend.tf"
grep -Fq 'profile      = "opensearch-lab-terraform"' "${success_fixture}/infra/bootstrap/backend.tf"
grep -Fq 'role/opensearch-lab-terraform-admin' "${success_fixture}/infra/bootstrap/backend.tf"
grep -Eq '^arn:aws:iam::[0-9]{12}:role/opensearch-lab-terraform-admin\|.* plan ' "${success_log}"
grep -Fq 's3api list-objects-v2 --profile opensearch-lab-terraform' "${success_log}"
test -s "$(find "${success_fixture}/.private/terraform-bootstrap" -name 'pre-migration-*.tfstate' -print -quit)"

occupied_fixture="$(make_fixture occupied)"
cp "${occupied_fixture}/infra/bootstrap/backend.tf" "${occupied_fixture}/expected-backend.tf"
if PATH="${occupied_fixture}/bin:${PATH}" \
  FAKE_LOG="${occupied_fixture}/commands.log" \
  FAKE_REMOTE_STATE=present \
  "${occupied_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved >/dev/null 2>&1; then
  echo "Migration unexpectedly accepted an occupied destination." >&2
  exit 1
fi
cmp -s "${occupied_fixture}/expected-backend.tf" "${occupied_fixture}/infra/bootstrap/backend.tf"

rollback_fixture="$(make_fixture rollback)"
cp "${rollback_fixture}/infra/bootstrap/backend.tf" "${rollback_fixture}/expected-backend.tf"
if PATH="${rollback_fixture}/bin:${PATH}" \
  FAKE_LOG="${rollback_fixture}/commands.log" \
  FAKE_MIGRATION_FAILURE=true \
  "${rollback_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved >/dev/null 2>&1; then
  echo "Migration failure was not propagated." >&2
  exit 1
fi
cmp -s "${rollback_fixture}/expected-backend.tf" "${rollback_fixture}/infra/bootstrap/backend.tf"

workspace_fixture="$(make_fixture workspace)"
if PATH="${workspace_fixture}/bin:${PATH}" \
  FAKE_LOG="${workspace_fixture}/commands.log" \
  FAKE_WORKSPACE=non-default \
  "${workspace_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved >/dev/null 2>&1; then
  echo "Migration unexpectedly accepted a non-default workspace." >&2
  exit 1
fi

extra_workspace_fixture="$(make_fixture extra-workspace)"
if PATH="${extra_workspace_fixture}/bin:${PATH}" \
  FAKE_LOG="${extra_workspace_fixture}/commands.log" \
  FAKE_EXTRA_WORKSPACE=true \
  "${extra_workspace_fixture}/infra/bootstrap/scripts/migrate-state.sh" --approved >/dev/null 2>&1; then
  echo "Migration unexpectedly accepted an inactive extra workspace." >&2
  exit 1
fi

echo "State migration safeguards passed."
