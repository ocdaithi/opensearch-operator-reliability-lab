#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
negative_case_count=0
synthetic_bucket_name="opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"

record_negative_case() {
  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: %s\n' "$1"
}

expect_render_failure() {
  local case_name="$1"
  local fixture_root="$2"
  local expected_diagnostic="$3"
  local bucket_name="${4:-}"
  local render_output

  if render_output="$(
    TF_STATE_BUCKET_NAME="${bucket_name}" \
      "${fixture_root}/infra/bootstrap/scripts/render-s3-backend.sh" 2>&1
  )"; then
    echo "Backend rendering unexpectedly accepted: ${case_name}" >&2
    exit 1
  fi
  if [[ "${render_output}" != "${expected_diagnostic}" ]]; then
    printf 'Backend rendering failed with an unexpected diagnostic for %s.\n' \
      "${case_name}" >&2
    printf 'Expected: %s\n' "${expected_diagnostic}" >&2
    printf 'Actual: %s\n' "${render_output:-<no output>}" >&2
    exit 1
  fi
  record_negative_case "${case_name}"
}

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
  cp "${source_root}/infra/bootstrap/scripts/check-backend-contract.sh" \
    "${fixture_root}/infra/bootstrap/scripts/check-backend-contract.sh"
  printf '%s\n' "${fixture_root}"
}

success_fixture="$(make_fixture success)"
TF_STATE_BUCKET_NAME="${synthetic_bucket_name}" \
  "${success_fixture}/infra/bootstrap/scripts/render-s3-backend.sh" >/dev/null
rendered_backend="${success_fixture}/infra/bootstrap/backend.tf"

grep -Fq "bucket       = \"${synthetic_bucket_name}\"" "${rendered_backend}"
grep -Fq 'key          = "bootstrap/terraform.tfstate"' "${rendered_backend}"
grep -Fq 'use_lockfile = true' "${rendered_backend}"
if grep -Eq '__TF_STATE_BUCKET_NAME__|profile[[:space:]]*=|assume_role' "${rendered_backend}"; then
  echo "Rendered backend contains an unresolved or local-only setting." >&2
  exit 1
fi
git -C "${success_fixture}" check-ignore -q "${rendered_backend}"

if stat -f '%Lp' "${rendered_backend}" >/dev/null 2>&1; then
  file_mode="$(stat -f '%Lp' "${rendered_backend}")"
else
  file_mode="$(stat -c '%a' "${rendered_backend}")"
fi
test "${file_mode}" = "600"

missing_fixture="$(make_fixture missing)"
expect_render_failure \
  "missing-bucket-name" \
  "${missing_fixture}" \
  "TF_STATE_BUCKET_NAME is missing or differs from the deterministic bucket contract."

invalid_fixture="$(make_fixture invalid)"
invalid_bucket_name="unrelated-bucket"
[[ "${invalid_bucket_name}" != "${synthetic_bucket_name}" ]]
expect_render_failure \
  "unexpected-bucket-name" \
  "${invalid_fixture}" \
  "TF_STATE_BUCKET_NAME is missing or differs from the deterministic bucket contract." \
  "${invalid_bucket_name}"

dotted_fixture="$(make_fixture dotted)"
dotted_bucket_name="${synthetic_bucket_name}.unexpected"
[[ "${dotted_bucket_name}" == *.* ]]
expect_render_failure \
  "dotted-bucket-name" \
  "${dotted_fixture}" \
  "TF_STATE_BUCKET_NAME is missing or differs from the deterministic bucket contract." \
  "${dotted_bucket_name}"

mutated_template_fixture="$(make_fixture mutated-template)"
sed -i.bak 's/encrypt      = true/encrypt      = false/' \
  "${mutated_template_fixture}/infra/bootstrap/backend.s3.tf.example"
rm "${mutated_template_fixture}/infra/bootstrap/backend.s3.tf.example.bak"
grep -Fq 'encrypt      = false' \
  "${mutated_template_fixture}/infra/bootstrap/backend.s3.tf.example"
expect_render_failure \
  "modified-template" \
  "${mutated_template_fixture}" \
  "The s3-template backend does not match its exact reviewed contract." \
  "${synthetic_bucket_name}"

test -f "${rendered_backend}"
expect_render_failure \
  "existing-backend-replacement" \
  "${success_fixture}" \
  "Refusing to replace the existing ignored backend.tf." \
  "${synthetic_bucket_name}"
grep -Fq "bucket       = \"${synthetic_bucket_name}\"" "${rendered_backend}"

printf 'S3 backend rendering safeguards passed (%d negative cases).\n' \
  "${negative_case_count}"
