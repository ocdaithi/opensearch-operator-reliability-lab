#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
negative_case_count=0

for command_name in git mktemp perl zip; do
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

account_fixture="$(make_fixture account-specific-iam-arn)"
account_id="$(printf '%s%s%s' 1234 5678 9012)"
printf 'arn:aws:iam::%s:role/synthetic\n' "${account_id}" \
  >"${account_fixture}/account.txt"
git -C "${account_fixture}" add .
expect_failure "account-specific-iam-arn" "account-specific IAM ARN"

bare_account_fixture="$(make_fixture bare-account-id)"
printf '%s\n' "${account_id}" >"${bare_account_fixture}/account.txt"
git -C "${bare_account_fixture}" add .
expect_failure "bare-account-id" "possible AWS account ID"

credential_fixture="$(make_fixture aws-access-key)"
credential_prefix="$(printf '%s%s' AK IA)"
credential_suffix="$(printf '%s%s' ABCDEFGH IJKLMNOP)"
printf 'credential=%s%s\n' "${credential_prefix}" "${credential_suffix}" \
  >"${credential_fixture}/credential.txt"
git -C "${credential_fixture}" add .
expect_failure "aws-access-key" "AWS access-key identifier"

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

disguised_plan_json_fixture="$(make_fixture disguised-plan-json)"
printf '%s\n' \
  '{"format_version":"1.2","terraform_version":"1.15.9","planned_values":{},"resource_changes":[],"configuration":{}}' \
  >"${disguised_plan_json_fixture}/review.json"
git -C "${disguised_plan_json_fixture}" add review.json
expect_failure "disguised-plan-json" "plan JSON is tracked under a disguised filename"

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
