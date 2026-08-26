#!/usr/bin/env bash

set -euo pipefail

if [[ "${1:-}" != "--approved" ]]; then
  echo "Refusing to migrate state without the explicit --approved flag." >&2
  exit 1
fi

for command_name in aws git jq terraform; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${command_name}" >&2
    exit 1
  fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
module_dir="${repository_root}/infra/bootstrap"
private_dir="${repository_root}/.private/terraform-bootstrap"
variables_file="${2:-${private_dir}/terraform.tfvars}"
backend_file="${module_dir}/backend.tf"
backend_cache_file="${module_dir}/.terraform/terraform.tfstate"
local_backend_example="${module_dir}/backend.local.tf.example"
backend_contract_script="${module_dir}/scripts/check-backend-contract.sh"
local_state_file="${private_dir}/terraform.tfstate"
verification_plan="${private_dir}/post-migration-lock-check.tfplan"
state_key="bootstrap/terraform.tfstate"
aws_profile="opensearch-lab-terraform"

if [[ ! -x "${backend_contract_script}" ]]; then
  echo "The exact backend-contract checker is unavailable." >&2
  exit 1
fi
"${backend_contract_script}" local "${local_backend_example}" >/dev/null
"${backend_contract_script}" local "${backend_file}" >/dev/null

if [[ ! -f "${variables_file}" ]]; then
  echo "The private Terraform variable file is missing." >&2
  exit 1
fi

mkdir -p "${private_dir}"
chmod 700 "${private_dir}"
umask 077

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
recovery_state="${private_dir}/pre-migration-${timestamp}.tfstate"
remote_state="${private_dir}/post-migration-${timestamp}.tfstate"
backend_recovery="${private_dir}/pre-migration-backend-${timestamp}.tf"
backend_cache_recovery="${private_dir}/pre-migration-backend-cache-${timestamp}.tfstate"
temporary_backend=""
temporary_cache_snapshot=""
temporary_local_state_restore=""
cached_backend_should_exist=false
local_state_recovery_ready=false

# `terraform state pull` can upgrade the state to the local CLI version:
# https://developer.hashicorp.com/terraform/cli/commands/state/pull
# terraform_version is therefore the sole field allowed to differ. Lineage,
# serial and every managed-state value must remain identical.
states_match() {
  local expected_state="$1"
  local actual_state="$2"

  jq -e -s '
    length == 2
    and all(.[]; type == "object")
    and (.[0].lineage | type == "string" and length > 0)
    and (.[1].lineage | type == "string" and length > 0)
    and (.[0].serial | type == "number" and . >= 0 and floor == .)
    and (.[1].serial | type == "number" and . >= 0 and floor == .)
    and (.[0].terraform_version | type == "string" and length > 0)
    and (.[1].terraform_version | type == "string" and length > 0)
    and .[0].lineage == .[1].lineage
    and .[0].serial == .[1].serial
    and (.[0] | del(.terraform_version)) == (.[1] | del(.terraform_version))
  ' "${expected_state}" "${actual_state}" >/dev/null
}

restore_backend_on_failure() {
  local exit_status=$?
  local rollback_errors=0

  trap - EXIT
  set +e

  if [[ -n "${temporary_backend}" ]]; then
    if ! rm -f -- "${temporary_backend}"; then
      echo "Rollback could not remove the temporary backend configuration." >&2
      rollback_errors=$((rollback_errors + 1))
    fi
  fi

  if [[ -n "${temporary_cache_snapshot}" ]]; then
    if ! rm -f -- "${temporary_cache_snapshot}"; then
      echo "Rollback could not remove the temporary backend-cache snapshot." >&2
      rollback_errors=$((rollback_errors + 1))
    fi
  fi

  if [[ -n "${temporary_local_state_restore}" ]]; then
    if ! rm -f -- "${temporary_local_state_restore}"; then
      echo "Rollback could not remove the temporary local-state restoration file." >&2
      rollback_errors=$((rollback_errors + 1))
    fi
  fi

  if ! cp "${backend_recovery}" "${backend_file}" || ! chmod 600 "${backend_file}"; then
    echo "Rollback could not restore backend.tf." >&2
    rollback_errors=$((rollback_errors + 1))
  fi

  if [[ "${cached_backend_should_exist}" == "true" ]]; then
    if ! mkdir -p "$(dirname "${backend_cache_file}")" ||
      ! cp "${backend_cache_recovery}" "${backend_cache_file}" ||
      ! chmod 600 "${backend_cache_file}"; then
      echo "Rollback could not restore Terraform's cached backend metadata." >&2
      rollback_errors=$((rollback_errors + 1))
    fi
  elif ! rm -f -- "${backend_cache_file}"; then
    echo "Rollback could not remove Terraform's newly created backend metadata." >&2
    rollback_errors=$((rollback_errors + 1))
  fi

  if [[ "${local_state_recovery_ready}" == "true" ]]; then
    if ! temporary_local_state_restore="$(mktemp "${private_dir}/terraform.tfstate.rollback.XXXXXX")" ||
      ! cp "${recovery_state}" "${temporary_local_state_restore}" ||
      ! chmod 600 "${temporary_local_state_restore}" ||
      ! mv "${temporary_local_state_restore}" "${local_state_file}"; then
      echo "Rollback could not restore the original local state." >&2
      rollback_errors=$((rollback_errors + 1))
    else
      temporary_local_state_restore=""
      if ! states_match "${recovery_state}" "${local_state_file}"; then
        echo "Rollback restored local state which does not match the recovery copy." >&2
        rollback_errors=$((rollback_errors + 1))
      fi
    fi

    if [[ -n "${temporary_local_state_restore}" ]]; then
      if ! rm -f -- "${temporary_local_state_restore}"; then
        echo "Rollback could not remove the failed local-state restoration file." >&2
        rollback_errors=$((rollback_errors + 1))
      fi
      temporary_local_state_restore=""
    fi
  fi

  if ((rollback_errors == 0)); then
    echo "Migration failed; backend.tf and cached backend metadata were restored." >&2
  else
    printf 'Migration failed and rollback was incomplete (%d rollback errors).\n' \
      "${rollback_errors}" >&2
  fi

  if ((exit_status == 0)); then
    exit_status=1
  fi
  exit "${exit_status}"
}

cp "${backend_file}" "${backend_recovery}"
chmod 600 "${backend_recovery}"

if [[ -e "${backend_cache_file}" ]]; then
  if [[ ! -f "${backend_cache_file}" ]]; then
    echo "Terraform's cached backend metadata is not a regular file." >&2
    exit 1
  fi
  cp "${backend_cache_file}" "${backend_cache_recovery}"
  chmod 600 "${backend_cache_recovery}"
  cached_backend_should_exist=true
fi

trap restore_backend_on_failure EXIT

AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" init -reconfigure -input=false >/dev/null

if [[ ! -s "${backend_cache_file}" ]]; then
  echo "Terraform did not materialise cached local-backend metadata." >&2
  exit 1
fi

temporary_cache_snapshot="$(mktemp "${private_dir}/backend-cache.tfstate.XXXXXX")"
cp "${backend_cache_file}" "${temporary_cache_snapshot}"
chmod 600 "${temporary_cache_snapshot}"
mv "${temporary_cache_snapshot}" "${backend_cache_recovery}"
temporary_cache_snapshot=""
cached_backend_should_exist=true

current_workspace="$(AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" workspace show)"
workspace_names="$(
  AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" workspace list |
    sed -E 's/^[*[:space:]]+//; s/[[:space:]]+$//' |
    sed '/^$/d'
)"

if [[ "${current_workspace}" != "default" || "${workspace_names}" != "default" ]]; then
  echo "State migration requires default to be the only Terraform workspace." >&2
  exit 1
fi

AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" state pull >"${recovery_state}"
test -s "${recovery_state}"
chmod 600 "${recovery_state}"

if [[ ! -s "${local_state_file}" ]] || ! states_match "${local_state_file}" "${recovery_state}"; then
  echo "The original local state does not match its recovery copy." >&2
  exit 1
fi
local_state_recovery_ready=true

state_bucket_name="$(AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" output -raw state_bucket_name)"
if [[ ! "${state_bucket_name}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  echo "The state bucket output is not a valid S3 bucket name." >&2
  exit 1
fi

terraform_admin_role_arn="$(AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" output -raw terraform_admin_role_arn)"
if [[ ! "${terraform_admin_role_arn}" =~ ^arn:[a-z0-9-]+:iam::[0-9]{12}:role/opensearch-lab-terraform-admin$ ]]; then
  echo "The Terraform administration role output is not the expected role ARN." >&2
  exit 1
fi

temporary_backend="$(mktemp "${private_dir}/backend.tf.XXXXXX")"

cat >"${temporary_backend}" <<EOF
terraform {
  backend "s3" {
    bucket       = "${state_bucket_name}"
    key          = "bootstrap/terraform.tfstate"
    profile      = "${aws_profile}"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true

    assume_role = {
      role_arn     = "${terraform_admin_role_arn}"
      session_name = "terraform-bootstrap-state"
    }
  }
}
EOF

TF_STATE_BUCKET_NAME="${state_bucket_name}" \
  TF_ADMIN_ROLE_ARN="${terraform_admin_role_arn}" \
  "${backend_contract_script}" s3-migration "${temporary_backend}" >/dev/null

remote_listing="$(
  aws s3api list-objects-v2 \
    --profile "${aws_profile}" \
    --bucket "${state_bucket_name}" \
    --prefix "${state_key}" \
    --output json
)"

if ! jq -e --arg state_key "${state_key}" '
  [
    .Contents[]?
    | select(.Key == $state_key or .Key == ($state_key + ".tflock"))
  ]
  | length == 0
' >/dev/null <<<"${remote_listing}"; then
  echo "The remote state destination is not empty; no migration was attempted." >&2
  exit 1
fi

mv "${temporary_backend}" "${backend_file}"
temporary_backend=""
chmod 600 "${backend_file}"

AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" init -migrate-state -force-copy -input=false
AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" state pull >"${remote_state}"
test -s "${remote_state}"
chmod 600 "${remote_state}"

if ! states_match "${recovery_state}" "${remote_state}"; then
  echo "Remote state differs from the recovered local state." >&2
  exit 1
fi

set +e
AWS_PROFILE="${aws_profile}" TF_VAR_terraform_admin_role_arn="${terraform_admin_role_arn}" \
  terraform -chdir="${module_dir}" plan \
  -detailed-exitcode \
  -input=false \
  -lock-timeout=60s \
  -out="${verification_plan}" \
  -refresh=false \
  -var-file="${variables_file}" \
  >/dev/null
plan_status=$?
set -e

if [[ -f "${verification_plan}" ]]; then
  chmod 600 "${verification_plan}"
fi

case "${plan_status}" in
  0)
    ;;
  2)
    echo "The post-migration plan contains changes; migration verification failed." >&2
    exit 1
    ;;
  *)
    echo "The post-migration plan could not complete." >&2
    exit 1
    ;;
esac

lock_key="${state_key}.tflock"
lock_listing="$(
  aws s3api list-objects-v2 \
    --profile "${aws_profile}" \
    --bucket "${state_bucket_name}" \
    --prefix "${lock_key}" \
    --output json
)"

if ! jq -e --arg lock_key "${lock_key}" '
  [.Contents[]? | select(.Key == $lock_key)] | length == 0
' >/dev/null <<<"${lock_listing}"; then
  echo "The post-migration plan left a Terraform state lock object behind." >&2
  exit 1
fi

trap - EXIT
echo "Remote state and native locking were verified. The private recovery copy was retained."
