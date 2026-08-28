#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bootstrap_directory="$(cd -- "${script_directory}/.." && pwd)"
source_generator="${script_directory}/generate-temporary-policy.sh"
account_id="$(printf '%s%s%s' 1234 5678 9012)"
state_bucket_name="synthetic-bootstrap-state-${account_id}"
wrong_account_id="$(printf '%s%s%s' 0000 0000 0000)"
test_root="$(mktemp -d)"
case_count=0

cleanup() {
  rm -rf -- "${test_root}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

file_mode() {
  local file_path="$1"

  if stat -f '%Lp' "${file_path}" >/dev/null 2>&1; then
    stat -f '%Lp' "${file_path}"
  else
    stat -c '%a' "${file_path}"
  fi
}

prepare_fixture() {
  local case_name="$1"
  local fixture_root="${test_root}/${case_name}"

  mkdir -p \
    "${fixture_root}/infra/bootstrap/policies" \
    "${fixture_root}/infra/bootstrap/scripts" \
    "${fixture_root}/output"
  cp "${source_generator}" \
    "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"
  cp "${bootstrap_directory}/policies/temporary-bootstrap-policy.template.json" \
    "${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
}

assert_no_staging_files() {
  local output_directory="$1"

  if compgen -G "${output_directory}/*.tmp.*" >/dev/null; then
    fail "renderer left a temporary file in ${output_directory}"
  fi
}

expect_failure() {
  local case_name="$1"
  local expected_diagnostic="$2"
  shift 2
  local fixture_output="${test_root}/${case_name}/output"
  local command_output

  if command_output="$({ "$@"; } 2>&1)"; then
    fail "${case_name} unexpectedly succeeded"
  fi
  if [[ -n "${expected_diagnostic}" ]] && \
    ! grep -Fq "${expected_diagnostic}" <<<"${command_output}"; then
    printf 'FAIL: %s returned an unexpected diagnostic:\n%s\n' \
      "${case_name}" "${command_output}" >&2
    exit 1
  fi
  if [[ -d "${fixture_output}" ]]; then
    assert_no_staging_files "${fixture_output}"
  fi
  case_count=$((case_count + 1))
  printf 'PASS: %s\n' "${case_name}"
}

assert_temporary_contract() {
  local policy_file="$1"

  jq -e \
    --arg account_id "${account_id}" \
    --arg bucket "${state_bucket_name}" '
      def list: if type == "array" then . else [.] end;
      def normalise:
        reduce .Statement[] as $statement ({};
          .[$statement.Sid] = {
            statement_keys: ($statement | keys | sort),
            effect: $statement.Effect,
            actions: ($statement.Action | list | sort),
            resources: ($statement.Resource | list | sort),
            condition: $statement.Condition
          }
        );
      def canonical: with_entries(
        .value.actions |= sort
        | .value.resources |= sort
        | .value.statement_keys = ["Action", "Condition", "Effect", "Resource", "Sid"]
      );
      . as $policy
      | [$policy.Statement[].Condition.DateLessThan["aws:CurrentTime"]]
        | unique as $expiries
      | select(($expiries | length) == 1)
      | $expiries[0] as $expiry
      | ("arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap") as $principal
      | ("arn:aws:signin:*:" + $account_id + ":session/*") as $session
      | def condition($boundary): {
          "ArnEquals": (
            {"aws:PrincipalArn": $principal}
            + if $boundary == null then {} else {"iam:PermissionsBoundary": $boundary} end
          ),
          "ArnLike": {"aws:SignInSessionArn": $session},
          "DateLessThan": {"aws:CurrentTime": $expiry}
        };
      ({
        "CreateAndTagExactStateBucket": {
          effect: "Allow",
          actions: ["s3:CreateBucket", "s3:TagResource"],
          resources: ["arn:aws:s3:::" + $bucket],
          condition: condition(null)
        },
        "ManageStateBucketControls": {
          effect: "Allow",
          actions: [
            "s3:GetAccelerateConfiguration", "s3:GetBucketAcl", "s3:GetBucketCORS",
            "s3:GetBucketLocation", "s3:GetBucketLogging",
            "s3:GetBucketObjectLockConfiguration", "s3:GetBucketOwnershipControls",
            "s3:GetBucketPolicy", "s3:GetBucketPublicAccessBlock",
            "s3:GetBucketRequestPayment", "s3:GetBucketVersioning", "s3:GetBucketWebsite",
            "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration",
            "s3:GetReplicationConfiguration", "s3:ListBucket", "s3:ListTagsForResource",
            "s3:PutBucketOwnershipControls", "s3:PutBucketPolicy",
            "s3:PutBucketPublicAccessBlock", "s3:PutBucketVersioning",
            "s3:PutEncryptionConfiguration", "s3:PutLifecycleConfiguration",
            "s3:UntagResource"
          ],
          resources: ["arn:aws:s3:::" + $bucket],
          condition: condition(null)
        },
        "ReadAndWriteTerraformState": {
          effect: "Allow",
          actions: ["s3:GetObject", "s3:PutObject"],
          resources: ["arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate"],
          condition: condition(null)
        },
        "ManageTerraformStateLock": {
          effect: "Allow",
          actions: ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"],
          resources: ["arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate.tflock"],
          condition: condition(null)
        },
        "ManageExactBootstrapBudget": {
          effect: "Allow",
          actions: [
            "budgets:ListTagsForResource", "budgets:ModifyBudget",
            "budgets:TagResource", "budgets:UntagResource", "budgets:ViewBudget"
          ],
          resources: ["arn:aws:budgets::" + $account_id + ":budget/opensearch-lab-monthly-cost"],
          condition: condition(null)
        },
        "ReadDefaultBillingViewData": {
          effect: "Allow",
          actions: ["billing:GetBillingViewData"],
          resources: ["arn:aws:billing::" + $account_id + ":billingview/primary"],
          condition: condition(null)
        },
        "CreateHumanRoleWithBoundary": {
          effect: "Allow",
          actions: ["iam:CreateRole", "iam:PutRolePolicy"],
          resources: ["arn:aws:iam::" + $account_id + ":role/opensearch-lab-terraform-admin"],
          condition: condition(
            "arn:aws:iam::" + $account_id
            + ":policy/opensearch-lab-terraform-admin-boundary"
          )
        },
        "CreateGitHubRoleWithBoundary": {
          effect: "Allow",
          actions: ["iam:CreateRole", "iam:PutRolePolicy"],
          resources: ["arn:aws:iam::" + $account_id + ":role/opensearch-lab-github-actions"],
          condition: condition(
            "arn:aws:iam::" + $account_id
            + ":policy/opensearch-lab-github-actions-boundary"
          )
        },
        "ReadAndTagExactBootstrapRoles": {
          effect: "Allow",
          actions: [
            "iam:GetRole", "iam:GetRolePolicy", "iam:ListAttachedRolePolicies",
            "iam:ListRolePolicies", "iam:ListRoleTags", "iam:TagRole"
          ],
          resources: [
            "arn:aws:iam::" + $account_id + ":role/opensearch-lab-terraform-admin",
            "arn:aws:iam::" + $account_id + ":role/opensearch-lab-github-actions"
          ],
          condition: condition(null)
        },
        "ManageExactGitHubOIDCProvider": {
          effect: "Allow",
          actions: [
            "iam:CreateOpenIDConnectProvider", "iam:GetOpenIDConnectProvider",
            "iam:ListOpenIDConnectProviderTags", "iam:TagOpenIDConnectProvider"
          ],
          resources: [
            "arn:aws:iam::" + $account_id
            + ":oidc-provider/token.actions.githubusercontent.com"
          ],
          condition: condition(null)
        },
        "ReadExactBootstrapUser": {
          effect: "Allow",
          actions: ["iam:GetUser"],
          resources: ["arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap"],
          condition: condition(null)
        }
      } | canonical) as $expected
      | $policy.Version == "2012-10-17"
        and ($policy | keys | sort) == ["Statement", "Version"]
        and ($policy.Statement | length) == 11
        and ($policy | normalise) == $expected
    ' "${policy_file}" >/dev/null
}

expect_contract_mutation() {
  local case_name="$1"
  local mutation="$2"
  local fixture_root="${test_root}/${case_name}"
  local template_file
  local mutated_file
  local resolved_policy

  prepare_fixture "${case_name}"
  template_file="${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
  mutated_file="${fixture_root}/mutated.json"
  jq "${mutation}" "${template_file}" >"${mutated_file}"
  mv "${mutated_file}" "${template_file}"
  resolved_policy="${fixture_root}/output/policy.json"
  if ! "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
    "${account_id}" "${state_bucket_name}" "${resolved_policy}" >/dev/null; then
    fail "${case_name} was rejected before the independent contract assertion"
  fi
  if assert_temporary_contract "${resolved_policy}"; then
    fail "${case_name} escaped the independent contract assertion"
  fi
  assert_no_staging_files "${fixture_root}/output"
  case_count=$((case_count + 1))
  printf 'PASS: %s\n' "${case_name}"
}

prepare_fixture missing-inputs
missing_generator="${test_root}/missing-inputs/infra/bootstrap/scripts/generate-temporary-policy.sh"
expect_failure missing-inputs "Usage:" "${missing_generator}"

prepare_fixture malformed-account
fixture_root="${test_root}/malformed-account"
expect_failure malformed-account "exactly 12 digits" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  1234 "${state_bucket_name}" "${fixture_root}/output/policy.json"

prepare_fixture malformed-bucket
fixture_root="${test_root}/malformed-bucket"
expect_failure malformed-bucket "valid exact S3 bucket name" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" Invalid_Bucket "${fixture_root}/output/policy.json"

prepare_fixture successful-render
fixture_root="${test_root}/successful-render"
resolved_policy="${fixture_root}/output/policy.json"
generation_started="$(jq -nr 'now | floor')"
"${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${resolved_policy}" >/dev/null
generation_finished="$(jq -nr 'now | floor')"
jq -e 'type == "object"' "${resolved_policy}" >/dev/null
[[ "$(file_mode "${resolved_policy}")" == "600" ]] || \
  fail "successful renderer output did not have mode 0600"
if grep -Eq '__[A-Z0-9_]+__' "${resolved_policy}"; then
  fail "successful renderer output retained a placeholder"
fi
jq -e \
  --arg account_id "${account_id}" \
  --arg bucket "${state_bucket_name}" \
  --argjson generation_started "${generation_started}" \
  --argjson generation_finished "${generation_finished}" '
    [.Statement[].Condition.DateLessThan["aws:CurrentTime"]] as $expiries
    | ($expiries | unique | length) == 1
      and ($expiries[0] | fromdateiso8601) > $generation_started
      and ($expiries[0] | fromdateiso8601) <= ($generation_finished + (4 * 60 * 60))
      and all(
        .Statement[];
        .Condition.ArnEquals["aws:PrincipalArn"]
          == ("arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap")
        and .Condition.ArnLike["aws:SignInSessionArn"]
          == ("arn:aws:signin:*:" + $account_id + ":session/*")
      )
      and any(.. | strings; . == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate"))
  ' "${resolved_policy}" >/dev/null || fail "temporary policy substitutions or expiry were incorrect"
assert_temporary_contract "${resolved_policy}" || \
  fail "successful render differed from the exact temporary-policy contract"
assert_no_staging_files "${fixture_root}/output"
case_count=$((case_count + 1))
echo "PASS: successful-render"

prepare_fixture existing-destination
fixture_root="${test_root}/existing-destination"
resolved_policy="${fixture_root}/output/policy.json"
printf 'preserve this file\n' >"${resolved_policy}"
expect_failure existing-destination "Refusing to overwrite existing destination" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${resolved_policy}"
[[ "$(<"${resolved_policy}")" == "preserve this file" ]] || \
  fail "existing destination was changed"

prepare_fixture directory-destination
fixture_root="${test_root}/directory-destination"
resolved_policy="${fixture_root}/output/policy.json"
mkdir "${resolved_policy}"
printf 'preserve this directory\n' >"${resolved_policy}/marker"
expect_failure directory-destination "Refusing to overwrite existing destination" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${resolved_policy}"
[[ -d "${resolved_policy}" && "$(<"${resolved_policy}/marker")" == "preserve this directory" ]] || \
  fail "existing directory destination was changed"

prepare_fixture symlink-destination
fixture_root="${test_root}/symlink-destination"
resolved_policy="${fixture_root}/output/policy.json"
referent="${fixture_root}/missing-referent"
ln -s "${referent}" "${resolved_policy}"
expect_failure symlink-destination "Refusing symlink destination" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${resolved_policy}"
[[ -L "${resolved_policy}" && ! -e "${referent}" ]] || \
  fail "symlink destination was changed"

prepare_fixture unresolved-placeholder
fixture_root="${test_root}/unresolved-placeholder"
template_file="${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
mutated_file="${fixture_root}/mutated.json"
jq '(.Statement[] | select(.Sid == "ReadExactBootstrapUser") | .Resource) +=
  "/__UNRESOLVED__"' "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure unresolved-placeholder "template placeholder" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${fixture_root}/output/policy.json"

prepare_fixture incorrect-account-substitution
fixture_root="${test_root}/incorrect-account-substitution"
template_file="${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
mutated_file="${fixture_root}/mutated.json"
jq --arg wrong_account_id "${wrong_account_id}" '
  (.Statement[] | select(.Sid == "ReadDefaultBillingViewData") | .Resource) =
    ("arn:aws:billing::" + $wrong_account_id + ":billingview/primary")
' \
  "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure incorrect-account-substitution "failed its security contract" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${fixture_root}/output/policy.json"

prepare_fixture incorrect-principal-binding
fixture_root="${test_root}/incorrect-principal-binding"
template_file="${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
mutated_file="${fixture_root}/mutated.json"
jq '(.Statement[] | select(.Sid == "ReadExactBootstrapUser") |
  .Condition.ArnEquals["aws:PrincipalArn"]) =
  "arn:aws:iam::__AWS_ACCOUNT_ID__:user/*"' \
  "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure incorrect-principal-binding "failed its security contract" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${fixture_root}/output/policy.json"

prepare_fixture incorrect-sign-in-session
fixture_root="${test_root}/incorrect-sign-in-session"
template_file="${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
mutated_file="${fixture_root}/mutated.json"
jq --arg wrong_account_id "${wrong_account_id}" '
  (.Statement[] | select(.Sid == "ReadExactBootstrapUser") |
    .Condition.ArnLike["aws:SignInSessionArn"]) =
    ("arn:aws:signin:*:" + $wrong_account_id + ":session/*")
' \
  "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure incorrect-sign-in-session "failed its security contract" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${fixture_root}/output/policy.json"

prepare_fixture legacy-principal-account
fixture_root="${test_root}/legacy-principal-account"
template_file="${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
mutated_file="${fixture_root}/mutated.json"
jq '(.Statement[].Condition.ArnLike["aws:SignInSessionArn"]) =
  "arn:aws:signin:*:${aws:PrincipalAccount}:session/*"' \
  "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure legacy-principal-account "failed its security contract" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${fixture_root}/output/policy.json"

prepare_fixture excessive-expiry
fixture_root="${test_root}/excessive-expiry"
generator="${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"
perl -0pi -e 's/lifetime_seconds=14400/lifetime_seconds=14401/' "${generator}"
expect_failure excessive-expiry "must not exceed four hours" \
  "${generator}" "${account_id}" "${state_bucket_name}" \
  "${fixture_root}/output/policy.json"

prepare_fixture missing-expiry
fixture_root="${test_root}/missing-expiry"
template_file="${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
mutated_file="${fixture_root}/mutated.json"
jq 'del(.Statement[0].Condition.DateLessThan)' \
  "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure missing-expiry "failed its security contract" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${fixture_root}/output/policy.json"

prepare_fixture invalid-json
fixture_root="${test_root}/invalid-json"
printf '{ invalid JSON\n' \
  >"${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
expect_failure invalid-json "" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${fixture_root}/output/policy.json"

prepare_fixture incorrect-file-permissions
fixture_root="${test_root}/incorrect-file-permissions"
generator="${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"
perl -0pi -e 's/chmod 0600/chmod 0644/' "${generator}"
expect_failure incorrect-file-permissions "does not have mode 0600" \
  "${generator}" "${account_id}" "${state_bucket_name}" \
  "${fixture_root}/output/policy.json"

prepare_fixture iam-broadening
fixture_root="${test_root}/iam-broadening"
template_file="${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
mutated_file="${fixture_root}/mutated.json"
jq '(.Statement[] | select(.Sid == "ReadExactBootstrapUser") | .Action) =
  ["iam:GetUser", "iam:AttachUserPolicy"]' \
  "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure iam-broadening "failed its security contract" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${fixture_root}/output/policy.json"

prepare_fixture resource-broadening
fixture_root="${test_root}/resource-broadening"
template_file="${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
mutated_file="${fixture_root}/mutated.json"
jq '(.Statement[] | select(.Sid == "ReadExactBootstrapUser") | .Resource) =
  "arn:aws:iam::__AWS_ACCOUNT_ID__:user/*"' \
  "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure resource-broadening "failed its security contract" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${account_id}" "${state_bucket_name}" "${fixture_root}/output/policy.json"

expect_contract_mutation \
  allowed-delete-on-state-object \
  '(.Statement[] | select(.Sid == "ReadAndWriteTerraformState") | .Action) += ["s3:DeleteObject"]'

expect_contract_mutation \
  allowed-action-moved-between-statements \
  '(.Statement[] | select(.Sid == "ReadExactBootstrapUser") | .Action) = "iam:GetRole"'

expect_contract_mutation \
  allowed-resource-moved-between-statements \
  '(.Statement[] | select(.Sid == "ReadExactBootstrapUser") | .Resource) = "arn:aws:iam::__AWS_ACCOUNT_ID__:role/opensearch-lab-terraform-admin"'

expect_contract_mutation \
  allowed-boundary-moved-between-statements \
  '(.Statement[] | select(.Sid == "CreateHumanRoleWithBoundary") | .Condition.ArnEquals["iam:PermissionsBoundary"]) = "arn:aws:iam::__AWS_ACCOUNT_ID__:policy/opensearch-lab-github-actions-boundary"'

expect_contract_mutation \
  unexpected-top-level-key \
  '.UnexpectedContractField = true'

printf 'Temporary-policy renderer tests passed: %d cases.\n' "${case_count}"
