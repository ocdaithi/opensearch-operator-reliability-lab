#!/usr/bin/env bash

set -euo pipefail

if (($# != 2)); then
  echo "Usage: check-backend-contract.sh <local|s3-template|s3-resolved|s3-migration> <file>" >&2
  exit 1
fi

contract="$1"
candidate_file="$2"

if [[ ! -f "${candidate_file}" ]]; then
  echo "The backend configuration is missing." >&2
  exit 1
fi

for command_name in cmp mktemp; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${command_name}" >&2
    exit 1
  fi
done

temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "${temporary_dir}"' EXIT
expected_file="${temporary_dir}/expected.tf"

validate_state_bucket_name() {
  state_bucket_name="${TF_STATE_BUCKET_NAME:-}"
  if [[ "${state_bucket_name}" != "opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1" ]]; then
    echo "TF_STATE_BUCKET_NAME is missing or differs from the deterministic bucket contract." >&2
    exit 1
  fi
}

case "${contract}" in
  local)
    cat >"${expected_file}" <<'EOF'
terraform {
  backend "local" {
    path = "../../.private/terraform-bootstrap/terraform.tfstate"
  }
}
EOF
    ;;
  s3-template)
    cat >"${expected_file}" <<'EOF'
terraform {
  backend "s3" {
    bucket       = "__TF_STATE_BUCKET_NAME__"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
EOF
    ;;
  s3-resolved)
    validate_state_bucket_name

    cat >"${expected_file}" <<EOF
terraform {
  backend "s3" {
    bucket       = "${state_bucket_name}"
    key          = "bootstrap/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
EOF
    ;;
  s3-migration)
    validate_state_bucket_name
    terraform_admin_role_arn="${TF_ADMIN_ROLE_ARN:-}"
    if [[ ! "${terraform_admin_role_arn}" =~ ^arn:aws:iam::[0-9]{12}:role/opensearch-lab-terraform-admin$ ]]; then
      echo "TF_ADMIN_ROLE_ARN is missing or differs from the exact administration role contract." >&2
      exit 1
    fi

    cat >"${expected_file}" <<EOF
terraform {
  backend "s3" {
    bucket       = "${state_bucket_name}"
    key          = "bootstrap/terraform.tfstate"
    profile      = "opensearch-lab-terraform"
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
    ;;
  *)
    echo "Unknown backend contract: ${contract}" >&2
    exit 1
    ;;
esac

if ! cmp -s "${expected_file}" "${candidate_file}"; then
  echo "The ${contract} backend does not match its exact reviewed contract." >&2
  exit 1
fi

echo "Exact ${contract} backend contract passed."
