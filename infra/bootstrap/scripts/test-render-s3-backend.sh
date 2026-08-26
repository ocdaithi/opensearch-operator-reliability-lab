#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT

make_fixture() {
  fixture_name="$1"
  fixture_root="${test_root}/${fixture_name}"

  mkdir -p "${fixture_root}/infra/bootstrap/scripts"
  git -C "${fixture_root}" init -q
  cp "${source_root}/.gitignore" "${fixture_root}/.gitignore"
  cp "${source_root}/infra/bootstrap/backend.s3.tf.example" \
    "${fixture_root}/infra/bootstrap/backend.s3.tf.example"
  cp "${source_root}/infra/bootstrap/scripts/render-s3-backend.sh" \
    "${fixture_root}/infra/bootstrap/scripts/render-s3-backend.sh"
  printf '%s\n' "${fixture_root}"
}

success_fixture="$(make_fixture success)"
TF_STATE_BUCKET_NAME=opensearch-lab-tfstate-synthetic \
  "${success_fixture}/infra/bootstrap/scripts/render-s3-backend.sh" >/dev/null
rendered_backend="${success_fixture}/infra/bootstrap/backend.tf"

grep -Fq 'bucket       = "opensearch-lab-tfstate-synthetic"' "${rendered_backend}"
grep -Fq 'key          = "bootstrap/terraform.tfstate"' "${rendered_backend}"
grep -Fq 'use_lockfile = true' "${rendered_backend}"
! grep -Eq '__TF_STATE_BUCKET_NAME__|profile[[:space:]]*=|assume_role' "${rendered_backend}"
git -C "${success_fixture}" check-ignore -q "${rendered_backend}"

if stat -f '%Lp' "${rendered_backend}" >/dev/null 2>&1; then
  file_mode="$(stat -f '%Lp' "${rendered_backend}")"
else
  file_mode="$(stat -c '%a' "${rendered_backend}")"
fi
test "${file_mode}" = "600"

missing_fixture="$(make_fixture missing)"
if "${missing_fixture}/infra/bootstrap/scripts/render-s3-backend.sh" >/dev/null 2>&1; then
  echo "Backend rendering unexpectedly accepted a missing bucket name." >&2
  exit 1
fi

invalid_fixture="$(make_fixture invalid)"
if TF_STATE_BUCKET_NAME=unrelated-bucket \
  "${invalid_fixture}/infra/bootstrap/scripts/render-s3-backend.sh" >/dev/null 2>&1; then
  echo "Backend rendering unexpectedly accepted an invalid bucket name." >&2
  exit 1
fi

if TF_STATE_BUCKET_NAME=opensearch-lab-tfstate-replacement \
  "${success_fixture}/infra/bootstrap/scripts/render-s3-backend.sh" >/dev/null 2>&1; then
  echo "Backend rendering unexpectedly replaced an existing configuration." >&2
  exit 1
fi
grep -Fq 'bucket       = "opensearch-lab-tfstate-synthetic"' "${rendered_backend}"

echo "S3 backend rendering safeguards passed."
