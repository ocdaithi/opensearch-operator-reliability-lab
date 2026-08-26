#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
negative_case_count=0

for command_name in git grep mktemp perl unzip zip; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${command_name}" >&2
    exit 1
  fi
done

make_fixture() {
  fixture_name="$1"
  fixture_root="${test_root}/${fixture_name}"

  mkdir -p \
    "${fixture_root}/.github/workflows" \
    "${fixture_root}/infra/bootstrap/tests"
  git -C "${fixture_root}" init -q
  cp "${source_root}/.gitignore" "${fixture_root}/.gitignore"
  cp "${source_root}/.github/workflows/terraform-validate.yml" \
    "${fixture_root}/.github/workflows/terraform-validate.yml"
  cp "${source_root}/.github/workflows/verify-aws-oidc.yml" \
    "${fixture_root}/.github/workflows/verify-aws-oidc.yml"
  cp "${source_root}/infra/bootstrap/tests/check-tracked-repository.sh" \
    "${fixture_root}/infra/bootstrap/tests/check-tracked-repository.sh"
  printf 'Synthetic repository safeguard fixture.\n' >"${fixture_root}/README.md"
  git -C "${fixture_root}" add .
  printf '%s\n' "${fixture_root}"
}

add_composite_action() {
  fixture_root="$1"
  action_name="$2"
  nested_reference="${3:-}"
  action_dir="${fixture_root}/.github/actions/${action_name}"

  mkdir -p "${action_dir}"
  {
    printf '%s\n' \
      "name: Synthetic ${action_name} action" \
      'description: Synthetic fixture action.' \
      'runs:' \
      '  using: composite' \
      '  steps:'
    if [[ -n "${nested_reference}" ]]; then
      printf '    - uses: %s\n' "${nested_reference}"
    else
      printf '%s\n' \
        '    - run: true' \
        '      shell: bash'
    fi
  } >"${action_dir}/action.yml"
}

reference_local_action() {
  fixture_root="$1"
  action_name="$2"
  printf '%s\n' \
    "      - name: Use ${action_name} local action" \
    "        uses: ./.github/actions/${action_name}" \
    >>"${fixture_root}/.github/workflows/terraform-validate.yml"
}

expect_failure() {
  case_name="$1"
  expected_error="$2"
  fixture_root="${test_root}/${case_name}"
  output_file="${fixture_root}/check.log"

  if "${fixture_root}/infra/bootstrap/tests/check-tracked-repository.sh" \
    >"${output_file}" 2>&1; then
    echo "Tracked repository safeguard unexpectedly accepted: ${case_name}" >&2
    exit 1
  fi
  if ! grep -Fq "${expected_error}" "${output_file}"; then
    echo "Tracked repository safeguard failed unexpectedly: ${case_name}" >&2
    tail -20 "${output_file}" >&2
    exit 1
  fi

  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: %s\n' "${case_name}"
}

baseline_fixture="$(make_fixture baseline)"
printf '%s\n' 'digest=d115920994021f' >"${baseline_fixture}/synthetic-digest.txt"
git -C "${baseline_fixture}" add synthetic-digest.txt
ignored_account_id="$(printf '%s%s%s' 2222 2222 2222)"
ignored_access_key_prefix="$(printf '%s%s' AK IA)"
ignored_access_key_suffix="$(printf '%s%s' QRSTUVWX YZABCDEF)"
ignored_secret_variable="$(printf '%s%s' AWS_SECRET_ ACCESS_KEY)"
ignored_secret_value="$(printf '%s%s%s%s' abcdefghij klmnopqrst uvwxyzABCD EFGHIJKLMN)"
ignored_private_key_marker="-----BEGIN $(printf '%s%s' PRIVATE ' ')KEY-----"
mkdir -p "${baseline_fixture}/.private"
printf '%s\n' \
  "arn:aws:iam::${ignored_account_id}:role/ignored" \
  "${ignored_access_key_prefix}${ignored_access_key_suffix}" \
  "${ignored_secret_variable}=${ignored_secret_value}" \
  "${ignored_private_key_marker}" \
  >"${baseline_fixture}/.private/ignored-sensitive-patterns.txt"
git -C "${baseline_fixture}" check-ignore -q .private/ignored-sensitive-patterns.txt
"${baseline_fixture}/infra/bootstrap/tests/check-tracked-repository.sh" >/dev/null
printf 'positive case: ignored-private-content-not-scanned\n'

local_action_fixture="$(make_fixture tracked-local-action)"
nested_action_sha="$(printf 'b%.0s' {1..40})"
add_composite_action "${local_action_fixture}" reviewed \
  "actions/checkout@${nested_action_sha}"
reference_local_action "${local_action_fixture}" reviewed
git -C "${local_action_fixture}" add .
"${local_action_fixture}/infra/bootstrap/tests/check-tracked-repository.sh" >/dev/null
printf 'positive case: pinned-nested-local-action\n'

unreferenced_action_fixture="$(make_fixture unreferenced-unpinned-action)"
add_composite_action "${unreferenced_action_fixture}" unreferenced \
  'actions/checkout@v4'
git -C "${unreferenced_action_fixture}" add .
expect_failure "unreferenced-unpinned-action" "not pinned to an immutable digest"

root_flow_action_fixture="$(make_fixture unreferenced-root-flow-action)"
mkdir -p "${root_flow_action_fixture}/.github/actions/root-flow"
printf '%s\n' \
  '{name: Unsafe, description: Unsafe, runs: {using: composite, steps: [{uses: actions/checkout@v4}]}}' \
  >"${root_flow_action_fixture}/.github/actions/root-flow/action.yml"
grep -Fq 'uses: actions/checkout@v4' \
  "${root_flow_action_fixture}/.github/actions/root-flow/action.yml"
git -C "${root_flow_action_fixture}" add .
expect_failure "unreferenced-root-flow-action" "Flow-style YAML mappings are not allowed"

unpinned_fixture="$(make_fixture unpinned-action)"
perl -0pi -e 's#actions/checkout@[0-9a-f]{40}#actions/checkout\@v4#' \
  "${unpinned_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq 'uses: actions/checkout@v4' \
  "${unpinned_fixture}/.github/workflows/terraform-validate.yml"
git -C "${unpinned_fixture}" add .
expect_failure "unpinned-action" "not pinned to an immutable digest"

quoted_unpinned_fixture="$(make_fixture quoted-unpinned-action)"
perl -0pi -e 's#uses: actions/checkout@[0-9a-f]{40}#"uses": actions/checkout\@v4#' \
  "${quoted_unpinned_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq '"uses": actions/checkout@v4' \
  "${quoted_unpinned_fixture}/.github/workflows/terraform-validate.yml"
git -C "${quoted_unpinned_fixture}" add .
expect_failure "quoted-unpinned-action" "Quoted or complex YAML mapping keys are not allowed"

escaped_uses_fixture="$(make_fixture escaped-uses-key)"
perl -0pi -e 's#uses: actions/checkout@[0-9a-f]{40}#"u\\u0073es": actions/checkout\@v4#' \
  "${escaped_uses_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq '"u\u0073es": actions/checkout@v4' \
  "${escaped_uses_fixture}/.github/workflows/terraform-validate.yml"
git -C "${escaped_uses_fixture}" add .
expect_failure "escaped-uses-key" "Quoted or complex YAML mapping keys are not allowed"

tagged_uses_fixture="$(make_fixture tagged-uses-key)"
perl -0pi -e 's#uses: actions/checkout@[0-9a-f]{40}#!!str uses: actions/checkout\@v4#' \
  "${tagged_uses_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq '!!str uses: actions/checkout@v4' \
  "${tagged_uses_fixture}/.github/workflows/terraform-validate.yml"
git -C "${tagged_uses_fixture}" add .
expect_failure "tagged-uses-key" "YAML tags, anchors and aliases are not allowed"

aliased_uses_fixture="$(make_fixture aliased-uses-key)"
perl -0pi -e 's#uses: actions/checkout@[0-9a-f]{40}#*uses_key: actions/checkout\@v4#' \
  "${aliased_uses_fixture}/.github/workflows/terraform-validate.yml"
printf '%s\n' 'env:' '  U: &uses_key uses' \
  >>"${aliased_uses_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq '*uses_key: actions/checkout@v4' \
  "${aliased_uses_fixture}/.github/workflows/terraform-validate.yml"
git -C "${aliased_uses_fixture}" add .
expect_failure "aliased-uses-key" "YAML tags, anchors and aliases are not allowed"

flow_unpinned_fixture="$(make_fixture flow-unpinned-action)"
printf '%s\n' \
  '      - { "uses": actions/checkout@v4 }' \
  >>"${flow_unpinned_fixture}/.github/workflows/terraform-validate.yml"
git -C "${flow_unpinned_fixture}" add .
expect_failure "flow-unpinned-action" "Flow-style YAML mappings are not allowed"

missing_local_action_fixture="$(make_fixture missing-local-action)"
printf '%s\n' \
  '      - name: Use missing local action' \
  '        uses: ./.github/actions/missing' \
  >>"${missing_local_action_fixture}/.github/workflows/terraform-validate.yml"
git -C "${missing_local_action_fixture}" add .
expect_failure "missing-local-action" "no tracked regular action metadata"

unpinned_nested_fixture="$(make_fixture unpinned-nested-local-action)"
add_composite_action "${unpinned_nested_fixture}" unpinned \
  'actions/checkout@main'
reference_local_action "${unpinned_nested_fixture}" unpinned
git -C "${unpinned_nested_fixture}" add .
expect_failure "unpinned-nested-local-action" "not pinned to an immutable digest"

nested_artifact_fixture="$(make_fixture nested-artifact-upload)"
nested_artifact_sha="$(printf 'c%.0s' {1..40})"
add_composite_action "${nested_artifact_fixture}" artifact \
  "actions/upload-artifact@${nested_artifact_sha}"
reference_local_action "${nested_artifact_fixture}" artifact
git -C "${nested_artifact_fixture}" add .
expect_failure "nested-artifact-upload" "Artifact upload actions require"

cycle_fixture="$(make_fixture local-action-cycle)"
add_composite_action "${cycle_fixture}" cycle-a \
  './.github/actions/cycle-b'
add_composite_action "${cycle_fixture}" cycle-b \
  './.github/actions/cycle-a'
reference_local_action "${cycle_fixture}" cycle-a
git -C "${cycle_fixture}" add .
expect_failure "local-action-cycle" "reference cycle is not allowed"

escape_fixture="$(make_fixture local-action-path-escape)"
add_composite_action "${escape_fixture}" escape './../outside'
reference_local_action "${escape_fixture}" escape
git -C "${escape_fixture}" add .
expect_failure "local-action-path-escape" "escapes its reviewed path"

runner_fixture="$(make_fixture floating-runner)"
perl -0pi -e 's/runs-on: ubuntu-24\.04/runs-on: ubuntu-latest/' \
  "${runner_fixture}/.github/workflows/terraform-validate.yml"
git -C "${runner_fixture}" add .
expect_failure "floating-runner" "differs from the reviewed ubuntu-24.04 image"

token_fixture="$(make_fixture id-token-expansion)"
perl -0pi -e 's/permissions:\n  contents: read/permissions:\n  contents: read\n  id-token: write/' \
  "${token_fixture}/.github/workflows/terraform-validate.yml"
git -C "${token_fixture}" add .
expect_failure "id-token-expansion" "outside the reviewed AWS OIDC workflow"

oidc_guard_condition_fixture="$(make_fixture oidc-guard-not-always)"
perl -0pi -e 's/    if: always\(\)/    if: cancelled()/' \
  "${oidc_guard_condition_fixture}/.github/workflows/verify-aws-oidc.yml"
grep -Fqx '    if: cancelled()' \
  "${oidc_guard_condition_fixture}/.github/workflows/verify-aws-oidc.yml"
git -C "${oidc_guard_condition_fixture}" add .
expect_failure "oidc-guard-not-always" "guard differs from its reviewed fail-closed contract"

oidc_guard_success_fixture="$(make_fixture oidc-guard-accepts-non-main)"
perl -0pi -e 's/            exit 1/            exit 0/' \
  "${oidc_guard_success_fixture}/.github/workflows/verify-aws-oidc.yml"
grep -Fqx '            exit 0' \
  "${oidc_guard_success_fixture}/.github/workflows/verify-aws-oidc.yml"
git -C "${oidc_guard_success_fixture}" add .
expect_failure "oidc-guard-accepts-non-main" "guard differs from its reviewed fail-closed contract"

oidc_second_token_fixture="$(make_fixture oidc-second-token-job)"
perl -0pi -e 's/    timeout-minutes: 1/    permissions:\n      id-token: write\n    timeout-minutes: 1/' \
  "${oidc_second_token_fixture}/.github/workflows/verify-aws-oidc.yml"
if [[ "$(grep -Fc '      id-token: write' \
  "${oidc_second_token_fixture}/.github/workflows/verify-aws-oidc.yml")" != "2" ]]; then
  echo "OIDC second-token mutation was not applied." >&2
  exit 1
fi
git -C "${oidc_second_token_fixture}" add .
expect_failure "oidc-second-token-job" "differs from its reviewed token boundary"

oidc_guard_environment_fixture="$(make_fixture oidc-environment-on-guard)"
perl -0pi -e 's/    timeout-minutes: 1/    environment: aws-bootstrap\n    timeout-minutes: 1/' \
  "${oidc_guard_environment_fixture}/.github/workflows/verify-aws-oidc.yml"
if [[ "$(grep -Fc '    environment: aws-bootstrap' \
  "${oidc_guard_environment_fixture}/.github/workflows/verify-aws-oidc.yml")" != "2" ]]; then
  echo "OIDC guard-environment mutation was not applied." >&2
  exit 1
fi
git -C "${oidc_guard_environment_fixture}" add .
expect_failure "oidc-environment-on-guard" "guard differs from its reviewed fail-closed contract"

oidc_missing_needs_fixture="$(make_fixture oidc-missing-guard-dependency)"
perl -0pi -e 's/    needs: guard\n//' \
  "${oidc_missing_needs_fixture}/.github/workflows/verify-aws-oidc.yml"
if grep -Fqx '    needs: guard' \
  "${oidc_missing_needs_fixture}/.github/workflows/verify-aws-oidc.yml"; then
  echo "OIDC guard-dependency mutation was not applied." >&2
  exit 1
fi
git -C "${oidc_missing_needs_fixture}" add .
expect_failure "oidc-missing-guard-dependency" "must depend only on the successful guard"

oidc_repository_permission_fixture="$(make_fixture oidc-repository-permission)"
perl -0pi -e 's/  contents: none/  contents: read/' \
  "${oidc_repository_permission_fixture}/.github/workflows/verify-aws-oidc.yml"
grep -Fqx '  contents: read' \
  "${oidc_repository_permission_fixture}/.github/workflows/verify-aws-oidc.yml"
git -C "${oidc_repository_permission_fixture}" add .
expect_failure "oidc-repository-permission" "permissions block differs from its reviewed contract"

permission_fixture="$(make_fixture workflow-write-permission)"
perl -0pi -e 's/contents: read/contents: write/' \
  "${permission_fixture}/.github/workflows/terraform-validate.yml"
git -C "${permission_fixture}" add .
expect_failure "workflow-write-permission" "unreviewed write permission"

job_permission_fixture="$(make_fixture job-write-all-permission)"
perl -0pi -e 's/(    runs-on: ubuntu-24\.04\n)/$1    permissions: write-all\n/' \
  "${job_permission_fixture}/.github/workflows/terraform-validate.yml"
git -C "${job_permission_fixture}" add .
expect_failure "job-write-all-permission" "Job-level workflow permissions are not allowed"

escaped_permission_fixture="$(make_fixture escaped-job-permissions)"
perl -0pi -e 's/(    runs-on: ubuntu-24\.04\n)/$1    "permi\\u0073sions":\n      "i\\u0064-token": write\n/' \
  "${escaped_permission_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq '"permi\u0073sions":' \
  "${escaped_permission_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq '"i\u0064-token": write' \
  "${escaped_permission_fixture}/.github/workflows/terraform-validate.yml"
git -C "${escaped_permission_fixture}" add .
expect_failure "escaped-job-permissions" "Quoted or complex YAML mapping keys are not allowed"

tagged_permission_fixture="$(make_fixture tagged-job-permissions)"
perl -0pi -e 's/(    runs-on: ubuntu-24\.04\n)/$1    !!str permissions:\n      !!str id-token: write\n/' \
  "${tagged_permission_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq '!!str permissions:' \
  "${tagged_permission_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq '!!str id-token: write' \
  "${tagged_permission_fixture}/.github/workflows/terraform-validate.yml"
git -C "${tagged_permission_fixture}" add .
expect_failure "tagged-job-permissions" "YAML tags, anchors and aliases are not allowed"

missing_permissions_fixture="$(make_fixture missing-workflow-permissions)"
printf '%s\n' \
  'name: Unreviewed workflow' \
  '' \
  'on:' \
  '  workflow_dispatch:' \
  '' \
  'jobs:' \
  '  test:' \
  '    runs-on: ubuntu-24.04' \
  '    steps:' \
  '      - run: true' \
  >"${missing_permissions_fixture}/.github/workflows/unreviewed.yml"
git -C "${missing_permissions_fixture}" add .
expect_failure "missing-workflow-permissions" "permissions block differs"

symlinked_workflow_fixture="$(make_fixture symlinked-workflow)"
mkdir -p "${symlinked_workflow_fixture}/.private"
cp "${symlinked_workflow_fixture}/.github/workflows/terraform-validate.yml" \
  "${symlinked_workflow_fixture}/.private/terraform-validate.yml"
rm "${symlinked_workflow_fixture}/.github/workflows/terraform-validate.yml"
ln -s ../../.private/terraform-validate.yml \
  "${symlinked_workflow_fixture}/.github/workflows/terraform-validate.yml"
git -C "${symlinked_workflow_fixture}" add \
  .github/workflows/terraform-validate.yml
expect_failure "symlinked-workflow" "reviewed workflow is not a tracked regular file"

trigger_fixture="$(make_fixture broad-feature-push-trigger)"
perl -0pi -e 's/push:\n    branches:\n      - main/push:/' \
  "${trigger_fixture}/.github/workflows/terraform-validate.yml"
git -C "${trigger_fixture}" add .
expect_failure "broad-feature-push-trigger" "trigger differs from the reviewed contract"

flow_runner_fixture="$(make_fixture flow-job-runner)"
printf '%s\n' \
  '  unsafe: { runs-on: ubuntu-latest, steps: [{ run: true }] }' \
  >>"${flow_runner_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq 'unsafe: { runs-on: ubuntu-latest' \
  "${flow_runner_fixture}/.github/workflows/terraform-validate.yml"
git -C "${flow_runner_fixture}" add .
expect_failure "flow-job-runner" "Flow-style YAML mappings are not allowed"

flow_reusable_fixture="$(make_fixture flow-reusable-workflow)"
printf '%s\n' \
  '  unsafe: { uses: owner/repository/.github/workflows/reuse.yml@main }' \
  >>"${flow_reusable_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq 'unsafe: { uses: owner/repository/.github/workflows/reuse.yml@main }' \
  "${flow_reusable_fixture}/.github/workflows/terraform-validate.yml"
git -C "${flow_reusable_fixture}" add .
expect_failure "flow-reusable-workflow" "Flow-style YAML mappings are not allowed"

external_reusable_fixture="$(make_fixture external-reusable-workflow)"
external_reusable_sha="$(printf 'd%.0s' {1..40})"
printf '%s\n' \
  '  external:' \
  '    name: Unreviewed external workflow' \
  "    uses: owner/repository/.github/workflows/reuse.yml@${external_reusable_sha}" \
  >>"${external_reusable_fixture}/.github/workflows/terraform-validate.yml"
grep -Fqx \
  "    uses: owner/repository/.github/workflows/reuse.yml@${external_reusable_sha}" \
  "${external_reusable_fixture}/.github/workflows/terraform-validate.yml"
git -C "${external_reusable_fixture}" add .
expect_failure "external-reusable-workflow" "External reusable-workflow jobs are not allowed"

anchored_flow_fixture="$(make_fixture anchored-flow-job)"
printf '%s\n' \
  '  unsafe: &job { runs-on: ubuntu-latest, steps: [{ run: true }] }' \
  '  clone: *job' \
  >>"${anchored_flow_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq 'unsafe: &job { runs-on: ubuntu-latest' \
  "${anchored_flow_fixture}/.github/workflows/terraform-validate.yml"
grep -Fq 'clone: *job' \
  "${anchored_flow_fixture}/.github/workflows/terraform-validate.yml"
git -C "${anchored_flow_fixture}" add .
expect_failure "anchored-flow-job" "YAML tags, anchors and aliases are not allowed"

artifact_fixture="$(make_fixture repository-artifact-upload)"
action_sha="$(printf 'a%.0s' {1..40})"
printf '%s\n' \
  '      - name: Upload repository' \
  "        uses: actions/upload-artifact@${action_sha}" \
  '        with:' \
  '          path: .' \
  >>"${artifact_fixture}/.github/workflows/terraform-validate.yml"
git -C "${artifact_fixture}" add .
expect_failure "repository-artifact-upload" "Artifact upload actions require"

mixed_case_artifact_fixture="$(make_fixture mixed-case-artifact-upload)"
printf '%s\n' \
  '      - name: Upload repository with mixed case' \
  "        uses: Actions/Upload-Artifact@${action_sha}" \
  '        with:' \
  '          path: .' \
  >>"${mixed_case_artifact_fixture}/.github/workflows/terraform-validate.yml"
grep -Fqx "        uses: Actions/Upload-Artifact@${action_sha}" \
  "${mixed_case_artifact_fixture}/.github/workflows/terraform-validate.yml"
git -C "${mixed_case_artifact_fixture}" add .
expect_failure "mixed-case-artifact-upload" "Artifact upload actions require"

account_fixture="$(make_fixture account-specific-iam-arn)"
account_id="$(printf '%s%s%s' 1234 5678 9012)"
printf 'arn:aws:iam::%s:role/synthetic\n' "${account_id}" \
  >"${account_fixture}/account.txt"
git -C "${account_fixture}" add .
expect_failure "account-specific-iam-arn" "account-specific IAM ARN"

binary_arn_fixture="$(make_fixture binary-account-specific-iam-arn)"
binary_arn="arn:aws:iam::${account_id}:role/synthetic"
printf '\0%s\n' "${binary_arn}" >"${binary_arn_fixture}/record.bin"
if grep -Iq '' "${binary_arn_fixture}/record.bin" ||
  ! grep -aFq "${binary_arn}" "${binary_arn_fixture}/record.bin"; then
  echo "Binary IAM ARN mutation was not applied." >&2
  exit 1
fi
git -C "${binary_arn_fixture}" add .
expect_failure "binary-account-specific-iam-arn" "account-specific IAM ARN"

bare_account_fixture="$(make_fixture bare-account-id)"
printf '%s\n' "${account_id}" >"${bare_account_fixture}/account.txt"
git -C "${bare_account_fixture}" add .
expect_failure "bare-account-id" "possible AWS account ID"

binary_account_fixture="$(make_fixture binary-account-id)"
printf '\0%s\n' "${account_id}" >"${binary_account_fixture}/record.bin"
if grep -Iq '' "${binary_account_fixture}/record.bin" ||
  ! grep -aFq "${account_id}" "${binary_account_fixture}/record.bin"; then
  echo "Binary account-ID mutation was not applied." >&2
  exit 1
fi
git -C "${binary_account_fixture}" add .
expect_failure "binary-account-id" "possible AWS account ID"

credential_fixture="$(make_fixture aws-access-key)"
credential_prefix="$(printf '%s%s' AK IA)"
credential_suffix="$(printf '%s%s' ABCDEFGH IJKLMNOP)"
printf 'credential=%s%s\n' "${credential_prefix}" "${credential_suffix}" \
  >"${credential_fixture}/credential.txt"
git -C "${credential_fixture}" add .
expect_failure "aws-access-key" "AWS access-key identifier"

binary_credential_fixture="$(make_fixture binary-aws-access-key)"
binary_credential="${credential_prefix}${credential_suffix}"
printf '\0credential=%s\n' "${binary_credential}" \
  >"${binary_credential_fixture}/record.bin"
if grep -Iq '' "${binary_credential_fixture}/record.bin" ||
  ! grep -aFq "${binary_credential}" "${binary_credential_fixture}/record.bin"; then
  echo "Binary AWS credential mutation was not applied." >&2
  exit 1
fi
git -C "${binary_credential_fixture}" add .
expect_failure "binary-aws-access-key" "AWS access-key identifier"

secret_fixture="$(make_fixture aws-secret-access-key)"
secret_variable="$(printf '%s%s' AWS_SECRET_ ACCESS_KEY)"
secret_value="$(printf '%s%s%s%s' abcdefghij klmnopqrst uvwxyzABCD EFGHIJKLMN)"
printf '%s=%s\n' "${secret_variable}" "${secret_value}" \
  >"${secret_fixture}/secret.txt"
git -C "${secret_fixture}" add .
expect_failure "aws-secret-access-key" "secret-access-key assignment"

quoted_secret_fixture="$(make_fixture quoted-aws-secret-access-key)"
printf '{"%s":"%s"}\n' "${secret_variable}" "${secret_value}" \
  >"${quoted_secret_fixture}/secret.json"
git -C "${quoted_secret_fixture}" add .
expect_failure "quoted-aws-secret-access-key" "secret-access-key assignment"

block_secret_fixture="$(make_fixture block-aws-secret-access-key)"
printf '%s\n' "${secret_variable}: >-" "  ${secret_value}" \
  >"${block_secret_fixture}/secret.yml"
git -C "${block_secret_fixture}" add .
expect_failure "block-aws-secret-access-key" "secret-access-key assignment"

private_key_label="$(printf '%s%s' PRIVATE ' KEY')"
for private_key_case in generic rsa ec encrypted openssh; do
  case "${private_key_case}" in
    generic)
      private_key_marker="-----BEGIN ${private_key_label}-----"
      ;;
    rsa)
      private_key_marker="-----BEGIN $(printf '%s%s' R SA) ${private_key_label}-----"
      ;;
    ec)
      private_key_marker="-----BEGIN $(printf '%s%s' E C) ${private_key_label}-----"
      ;;
    encrypted)
      private_key_marker="-----BEGIN $(printf '%s%s' ENCRYPT ED) ${private_key_label}-----"
      ;;
    openssh)
      private_key_marker="-----BEGIN $(printf '%s%s' OPEN SSH) ${private_key_label}-----"
      ;;
  esac

  private_key_fixture="$(make_fixture "private-key-${private_key_case}")"
  printf '%s\n' "${private_key_marker}" >"${private_key_fixture}/private-key.txt"
  git -C "${private_key_fixture}" add .
  expect_failure "private-key-${private_key_case}" "private key is present"
done

state_fixture="$(make_fixture tracked-state)"
printf '{}\n' >"${state_fixture}/infra/bootstrap/leak.tfstate"
git -C "${state_fixture}" add -f infra/bootstrap/leak.tfstate
expect_failure "tracked-state" "state or plan artefact is tracked"

kubeconfig_fixture="$(make_fixture tracked-kubeconfig)"
printf '%s\n' 'apiVersion: v1' >"${kubeconfig_fixture}/kubeconfig"
git -C "${kubeconfig_fixture}" add -f kubeconfig
expect_failure "tracked-kubeconfig" "A kubeconfig is tracked."

renamed_kubeconfig_fixture="$(make_fixture renamed-kubeconfig)"
printf '%s\n' \
  'apiVersion: v1' \
  'kind: Config' \
  'clusters: []' \
  'contexts: []' \
  'current-context: synthetic' \
  'users: []' \
  >"${renamed_kubeconfig_fixture}/cluster.yaml"
git -C "${renamed_kubeconfig_fixture}" add cluster.yaml
expect_failure "renamed-kubeconfig" "Kubeconfig content is tracked under a disguised filename."

disguised_state_fixture="$(make_fixture disguised-state)"
printf '%s\n' \
  '{"version":4,"terraform_version":"1.15.9","serial":1,"lineage":"synthetic","resources":[]}' \
  >"${disguised_state_fixture}/evidence.json"
git -C "${disguised_state_fixture}" add .
expect_failure "disguised-state" "state content is tracked under a disguised filename"

disguised_state_text_fixture="$(make_fixture disguised-state-text)"
printf '%s\n' \
  '{"version":4,"terraform_version":"1.15.9","serial":1,"lineage":"synthetic","resources":[]}' \
  >"${disguised_state_text_fixture}/evidence.txt"
git -C "${disguised_state_text_fixture}" add .
expect_failure "disguised-state-text" "state content is tracked under a disguised filename"

binary_state_fixture="$(make_fixture binary-disguised-state)"
binary_state_payload='{"version":4,"terraform_version":"1.15.9","serial":1,"lineage":"synthetic","resources":[]}'
printf '\0%s\n' "${binary_state_payload}" >"${binary_state_fixture}/evidence.bin"
if grep -Iq '' "${binary_state_fixture}/evidence.bin" ||
  ! grep -aFq '"lineage":"synthetic"' "${binary_state_fixture}/evidence.bin"; then
  echo "Binary Terraform state mutation was not applied." >&2
  exit 1
fi
git -C "${binary_state_fixture}" add .
expect_failure "binary-disguised-state" "state content is tracked in a binary-classified file"

disguised_plan_fixture="$(make_fixture disguised-plan-archive)"
plan_payload="${disguised_plan_fixture}/plan-payload"
mkdir -p "${plan_payload}"
printf 'synthetic plan\n' >"${plan_payload}/tfplan"
printf 'synthetic state\n' >"${plan_payload}/tfstate"
printf 'synthetic previous state\n' >"${plan_payload}/tfstate-prev"
(
  cd "${plan_payload}"
  zip -q "${disguised_plan_fixture}/review.plan" tfplan tfstate tfstate-prev
)
git -C "${disguised_plan_fixture}" add review.plan
expect_failure "disguised-plan-archive" "plan archive is tracked under a disguised filename"

nested_state_archive_fixture="$(make_fixture nested-state-archive)"
nested_archive_payload="${nested_state_archive_fixture}/archive-payload"
mkdir -p "${nested_archive_payload}/nested"
printf 'synthetic state\n' >"${nested_archive_payload}/nested/terraform.tfstate"
(
  cd "${nested_archive_payload}"
  zip -q "${nested_state_archive_fixture}/review.zip" nested/terraform.tfstate
)
unzip -Z1 "${nested_state_archive_fixture}/review.zip" |
  grep -Fqx 'nested/terraform.tfstate'
git -C "${nested_state_archive_fixture}" add review.zip
expect_failure "nested-state-archive" "archive contains a prohibited generated, private, state or plan artefact"

disguised_plan_json_fixture="$(make_fixture disguised-plan-json)"
printf '%s\n' \
  '{"format_version":"1.2","terraform_version":"1.15.9","planned_values":{},"resource_changes":[],"configuration":{}}' \
  >"${disguised_plan_json_fixture}/review.json"
git -C "${disguised_plan_json_fixture}" add review.json
expect_failure "disguised-plan-json" "plan JSON is tracked under a disguised filename"

binary_plan_fixture="$(make_fixture binary-disguised-plan-json)"
binary_plan_payload='{"format_version":"1.2","terraform_version":"1.15.9","planned_values":{},"resource_changes":[],"configuration":{}}'
printf '\0%s\n' "${binary_plan_payload}" >"${binary_plan_fixture}/review.bin"
if grep -Iq '' "${binary_plan_fixture}/review.bin" ||
  ! grep -aFq '"resource_changes":[]' "${binary_plan_fixture}/review.bin"; then
  echo "Binary Terraform plan mutation was not applied." >&2
  exit 1
fi
git -C "${binary_plan_fixture}" add .
expect_failure "binary-disguised-plan-json" "plan content is tracked in a binary-classified file"

private_fixture="$(make_fixture tracked-private-file)"
mkdir -p "${private_fixture}/.private"
printf 'private\n' >"${private_fixture}/.private/record.txt"
git -C "${private_fixture}" add -f .private/record.txt
expect_failure "tracked-private-file" "private, state or plan artefact is tracked"

nested_private_fixture="$(make_fixture tracked-nested-private-file)"
mkdir -p "${nested_private_fixture}/components/example/.private"
printf 'private\n' >"${nested_private_fixture}/components/example/.private/record.txt"
git -C "${nested_private_fixture}" add .
expect_failure "tracked-nested-private-file" "private, state or plan artefact is tracked"

alternate_backend_fixture="$(make_fixture tracked-alternate-backend)"
mkdir -p "${alternate_backend_fixture}/components/example"
printf '%s\n' 'terraform { backend "local" {} }' \
  >"${alternate_backend_fixture}/components/example/backend.tf"
git -C "${alternate_backend_fixture}" add .
expect_failure "tracked-alternate-backend" "private, state or plan artefact is tracked"

printf 'Tracked repository mutation safeguards passed (%d negative cases).\n' \
  "${negative_case_count}"
