#!/usr/bin/env bash

set -euo pipefail

if (($# != 0)); then
  echo "This command does not accept arguments." >&2
  exit 1
fi

for command_name in git mktemp sed; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${command_name}" >&2
    exit 1
  fi
done

state_bucket_name="${TF_STATE_BUCKET_NAME:-}"
if [[ "${state_bucket_name}" != "opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1" ]]; then
  echo "TF_STATE_BUCKET_NAME is missing or differs from the deterministic bucket contract." >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
module_dir="${repository_root}/infra/bootstrap"
template_file="${module_dir}/backend.s3.tf.example"
backend_file="${module_dir}/backend.tf"
private_dir="${repository_root}/.private/terraform-bootstrap"
placeholder="__TF_STATE_BUCKET_NAME__"
contract_script="${script_dir}/check-backend-contract.sh"

if [[ -e "${backend_file}" ]]; then
  echo "Refusing to replace the existing ignored backend.tf." >&2
  exit 1
fi

"${contract_script}" s3-template "${template_file}" >/dev/null

mkdir -p "${private_dir}"
chmod 700 "${private_dir}"
umask 077
temporary_file="$(mktemp "${private_dir}/backend.tf.XXXXXX")"
trap 'rm -f -- "${temporary_file}"' EXIT

sed "s/${placeholder}/${state_bucket_name}/" "${template_file}" >"${temporary_file}"

TF_STATE_BUCKET_NAME="${state_bucket_name}" \
  "${contract_script}" s3-resolved "${temporary_file}" >/dev/null

chmod 600 "${temporary_file}"
mv "${temporary_file}" "${backend_file}"
trap - EXIT

echo "Ignored S3 backend configuration materialised."
