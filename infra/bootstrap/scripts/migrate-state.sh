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
local_backend_example="${module_dir}/backend.local.tf.example"
verification_plan="${private_dir}/post-migration-lock-check.tfplan"
state_key="bootstrap/terraform.tfstate"
aws_profile="opensearch-lab-terraform"

if [[ ! -f "${backend_file}" ]] || ! cmp -s "${local_backend_example}" "${backend_file}"; then
  echo "The ignored backend.tf must match backend.local.tf.example exactly." >&2
  exit 1
fi

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
temporary_backend=""
migration_verified=false

restore_backend_on_failure() {
  exit_status=$?

  if [[ -n "${temporary_backend}" ]]; then
    rm -f -- "${temporary_backend}"
  fi

  if [[ "${migration_verified}" != "true" && -f "${backend_recovery}" ]]; then
    cp "${backend_recovery}" "${backend_file}"
    chmod 600 "${backend_file}"
  fi

  exit "${exit_status}"
}

trap restore_backend_on_failure EXIT

cp "${backend_file}" "${backend_recovery}"
chmod 600 "${backend_recovery}"

AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" init -reconfigure -input=false >/dev/null

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

remote_listing="$(
  aws s3api list-objects-v2 \
    --profile "${aws_profile}" \
    --bucket "${state_bucket_name}" \
    --prefix "${state_key}" \
    --max-keys 2 \
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

mv "${temporary_backend}" "${backend_file}"
temporary_backend=""
chmod 600 "${backend_file}"

AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" init -migrate-state -force-copy -input=false
AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" state pull >"${remote_state}"
test -s "${remote_state}"

local_lineage="$(jq -er '.lineage | select(type == "string" and length > 0)' "${recovery_state}")"
remote_lineage="$(jq -er '.lineage | select(type == "string" and length > 0)' "${remote_state}")"
local_serial="$(jq -er '.serial | select(type == "number")' "${recovery_state}")"
remote_serial="$(jq -er '.serial | select(type == "number")' "${remote_state}")"

if [[ "${local_lineage}" != "${remote_lineage}" ]] || ((remote_serial < local_serial)); then
  echo "Remote state verification failed; the private recovery copy was retained." >&2
  exit 1
fi

AWS_PROFILE="${aws_profile}" TF_VAR_terraform_admin_role_arn="${terraform_admin_role_arn}" \
  terraform -chdir="${module_dir}" plan \
  -input=false \
  -lock-timeout=60s \
  -out="${verification_plan}" \
  -refresh=false \
  -var-file="${variables_file}" \
  >/dev/null

migration_verified=true
echo "Remote state and native locking were verified. The private recovery copy was retained."
