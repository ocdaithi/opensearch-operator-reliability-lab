#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bootstrap_directory="$(cd -- "${script_directory}/.." && pwd)"
source_generator="${script_directory}/generate-permissions-boundaries.sh"
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
    "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"
  cp "${bootstrap_directory}/policies/terraform-admin-boundary.template.json" \
    "${fixture_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json"
  cp "${bootstrap_directory}/policies/github-actions-boundary.template.json" \
    "${fixture_root}/infra/bootstrap/policies/github-actions-boundary.template.json"
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

assert_boundary_contract() {
  local human_policy="$1"
  local github_policy="$2"

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
            condition: ($statement.Condition // null)
          }
        );
      def canonical: with_entries(
        .value.actions |= sort
        | .value.resources |= sort
        | .value.statement_keys = (
          if .value.condition == null then
            ["Action", "Effect", "Resource", "Sid"]
          else
            ["Action", "Condition", "Effect", "Resource", "Sid"]
          end
        )
      );
      . as $policy
      | ({
        "ReadAndWriteTerraformState": {
          effect: "Allow",
          actions: ["s3:GetObject", "s3:PutObject"],
          resources: ["arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate"],
          condition: null
        },
        "ManageTerraformStateLock": {
          effect: "Allow",
          actions: ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"],
          resources: ["arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate.tflock"],
          condition: null
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
            "s3:PutBucketOwnershipControls", "s3:PutBucketPublicAccessBlock",
            "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration",
            "s3:PutLifecycleConfiguration", "s3:TagResource", "s3:UntagResource"
          ],
          resources: ["arn:aws:s3:::" + $bucket],
          condition: null
        },
        "ManageBootstrapBudget": {
          effect: "Allow",
          actions: [
            "budgets:ListTagsForResource", "budgets:ModifyBudget",
            "budgets:TagResource", "budgets:UntagResource", "budgets:ViewBudget"
          ],
          resources: ["arn:aws:budgets::" + $account_id + ":budget/opensearch-lab-monthly-cost"],
          condition: null
        },
        "ReadDefaultBillingViewData": {
          effect: "Allow",
          actions: ["billing:GetBillingViewData"],
          resources: ["arn:aws:billing::" + $account_id + ":billingview/primary"],
          condition: null
        },
        "ReadExactBootstrapRoles": {
          effect: "Allow",
          actions: [
            "iam:GetRole", "iam:GetRolePolicy", "iam:ListAttachedRolePolicies",
            "iam:ListRolePolicies", "iam:ListRoleTags"
          ],
          resources: [
            "arn:aws:iam::" + $account_id + ":role/opensearch-lab-terraform-admin",
            "arn:aws:iam::" + $account_id + ":role/opensearch-lab-github-actions"
          ],
          condition: null
        },
        "ReadExactGitHubOIDCProvider": {
          effect: "Allow",
          actions: ["iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviderTags"],
          resources: [
            "arn:aws:iam::" + $account_id
            + ":oidc-provider/token.actions.githubusercontent.com"
          ],
          condition: null
        },
        "AuditExactBootstrapUser": {
          effect: "Allow",
          actions: [
            "iam:GetUser", "iam:ListAccessKeys", "iam:ListAttachedUserPolicies",
            "iam:ListGroupsForUser", "iam:ListMFADevices", "iam:ListUserPolicies"
          ],
          resources: ["arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap"],
          condition: null
        },
        "ReadExactPermissionsBoundaries": {
          effect: "Allow",
          actions: ["iam:GetPolicy", "iam:GetPolicyVersion"],
          resources: [
            "arn:aws:iam::" + $account_id
            + ":policy/opensearch-lab-terraform-admin-boundary",
            "arn:aws:iam::" + $account_id
            + ":policy/opensearch-lab-github-actions-boundary"
          ],
          condition: null
        },
        "DetachReviewedTemporaryBootstrapPolicy": {
          effect: "Allow",
          actions: ["iam:DetachUserPolicy"],
          resources: ["arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap"],
          condition: {
            "ArnEquals": {
              "iam:PolicyARN": (
                "arn:aws:iam::" + $account_id
                + ":policy/opensearch-lab-temporary-bootstrap"
              )
            }
          }
        },
        "DeleteReviewedTemporaryBootstrapPolicy": {
          effect: "Allow",
          actions: [
            "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion",
            "iam:ListEntitiesForPolicy"
          ],
          resources: [
            "arn:aws:iam::" + $account_id + ":policy/opensearch-lab-temporary-bootstrap"
          ],
          condition: null
        }
      } | canonical) as $expected
      | $policy.Version == "2012-10-17"
        and ($policy | keys | sort) == ["Statement", "Version"]
        and ($policy.Statement | length) == 11
        and ($policy | normalise) == $expected
    ' "${human_policy}" >/dev/null &&
    jq -e --arg bucket "${state_bucket_name}" '
      def list: if type == "array" then . else [.] end;
      def normalise:
        reduce .Statement[] as $statement ({};
          .[$statement.Sid] = {
            statement_keys: ($statement | keys | sort),
            effect: $statement.Effect,
            actions: ($statement.Action | list | sort),
            resources: ($statement.Resource | list | sort),
            condition: ($statement.Condition // null)
          }
        );
      def canonical: with_entries(
        .value.statement_keys = (
          if .value.condition == null then
            ["Action", "Effect", "Resource", "Sid"]
          else
            ["Action", "Condition", "Effect", "Resource", "Sid"]
          end
        )
      );
      . as $policy
      | ({
        "ListExactTerraformStateKeys": {
          effect: "Allow",
          actions: ["s3:ListBucket"],
          resources: ["arn:aws:s3:::" + $bucket],
          condition: {
            "StringEquals": {
              "s3:prefix": [
                "bootstrap/terraform.tfstate",
                "bootstrap/terraform.tfstate.tflock"
              ]
            }
          }
        },
        "ReadAndWriteTerraformState": {
          effect: "Allow",
          actions: ["s3:GetObject", "s3:PutObject"],
          resources: ["arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate"],
          condition: null
        },
        "ManageTerraformStateLock": {
          effect: "Allow",
          actions: ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"],
          resources: ["arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate.tflock"],
          condition: null
        }
      } | canonical) as $expected
      | $policy.Version == "2012-10-17"
        and ($policy | keys | sort) == ["Statement", "Version"]
        and ($policy.Statement | length) == 3
        and ($policy | normalise) == $expected
    ' "${github_policy}" >/dev/null
}

expect_contract_mutation() {
  local case_name="$1"
  local template_name="$2"
  local mutation="$3"
  local fixture_root="${test_root}/${case_name}"
  local template_file
  local mutated_file
  local human_output
  local github_output

  prepare_fixture "${case_name}"
  template_file="${fixture_root}/infra/bootstrap/policies/${template_name}"
  mutated_file="${fixture_root}/mutated.json"
  jq "${mutation}" "${template_file}" >"${mutated_file}"
  mv "${mutated_file}" "${template_file}"
  human_output="${fixture_root}/output/human.json"
  github_output="${fixture_root}/output/github.json"
  if ! "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
    "${account_id}" "${state_bucket_name}" "${human_output}" "${github_output}" >/dev/null; then
    fail "${case_name} was rejected before the independent contract assertion"
  fi
  if assert_boundary_contract "${human_output}" "${github_output}"; then
    fail "${case_name} escaped the independent contract assertion"
  fi
  assert_no_staging_files "${fixture_root}/output"
  case_count=$((case_count + 1))
  printf 'PASS: %s\n' "${case_name}"
}

prepare_fixture missing-inputs
missing_generator="${test_root}/missing-inputs/infra/bootstrap/scripts/generate-permissions-boundaries.sh"
expect_failure missing-inputs "Usage:" "${missing_generator}"

prepare_fixture malformed-account
fixture_root="${test_root}/malformed-account"
expect_failure malformed-account "exactly 12 digits" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  1234 "${state_bucket_name}" \
  "${fixture_root}/output/human.json" "${fixture_root}/output/github.json"

prepare_fixture malformed-bucket
fixture_root="${test_root}/malformed-bucket"
expect_failure malformed-bucket "valid exact S3 bucket name" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" Invalid_Bucket \
  "${fixture_root}/output/human.json" "${fixture_root}/output/github.json"

prepare_fixture successful-render
fixture_root="${test_root}/successful-render"
human_output="${fixture_root}/output/human.json"
github_output="${fixture_root}/output/github.json"
"${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" "${state_bucket_name}" "${human_output}" "${github_output}" >/dev/null
for resolved_file in "${human_output}" "${github_output}"; do
  jq -e 'type == "object"' "${resolved_file}" >/dev/null
  [[ "$(file_mode "${resolved_file}")" == "600" ]] || \
    fail "successful renderer output did not have mode 0600"
  if grep -Eq '__[A-Z0-9_]+__' "${resolved_file}"; then
    fail "successful renderer output retained a placeholder"
  fi
done
assert_boundary_contract "${human_output}" "${github_output}" || \
  fail "successful render differed from the exact permissions-boundary contract"
assert_no_staging_files "${fixture_root}/output"
case_count=$((case_count + 1))
echo "PASS: successful-render"

prepare_fixture existing-destination
fixture_root="${test_root}/existing-destination"
human_output="${fixture_root}/output/human.json"
github_output="${fixture_root}/output/github.json"
printf 'preserve this file\n' >"${human_output}"
expect_failure existing-destination "Refusing to overwrite existing destination" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" "${state_bucket_name}" "${human_output}" "${github_output}"
[[ "$(<"${human_output}")" == "preserve this file" ]] || \
  fail "existing destination was changed"

prepare_fixture directory-destination
fixture_root="${test_root}/directory-destination"
human_output="${fixture_root}/output/human.json"
github_output="${fixture_root}/output/github.json"
mkdir "${github_output}"
printf 'preserve this directory\n' >"${github_output}/marker"
expect_failure directory-destination "Refusing to overwrite existing destination" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" "${state_bucket_name}" "${human_output}" "${github_output}"
[[ -d "${github_output}" && "$(<"${github_output}/marker")" == "preserve this directory" ]] || \
  fail "existing directory destination was changed"

prepare_fixture symlink-destination
fixture_root="${test_root}/symlink-destination"
human_output="${fixture_root}/output/human.json"
github_output="${fixture_root}/output/github.json"
referent="${fixture_root}/missing-referent"
ln -s "${referent}" "${human_output}"
expect_failure symlink-destination "Refusing symlink destination" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" "${state_bucket_name}" "${human_output}" "${github_output}"
[[ -L "${human_output}" && ! -e "${referent}" ]] || \
  fail "symlink destination was changed"

prepare_fixture aliased-boundary-outputs
fixture_root="${test_root}/aliased-boundary-outputs"
human_output="${fixture_root}/output/policy.json"
github_output="${fixture_root}/output/../output/policy.json"
expect_failure aliased-boundary-outputs "Could not publish without overwriting destination" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" "${state_bucket_name}" "${human_output}" "${github_output}"
jq -e '.Statement | length == 11' "${human_output}" >/dev/null || \
  fail "aliased output replaced the Terraform administration boundary"

prepare_fixture unresolved-placeholder
fixture_root="${test_root}/unresolved-placeholder"
template_file="${fixture_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json"
mutated_file="${fixture_root}/mutated.json"
jq '(.Statement[] | select(.Sid == "ReadAndWriteTerraformState") | .Resource) += "/__UNRESOLVED__"' \
  "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure unresolved-placeholder "template placeholder" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" "${state_bucket_name}" \
  "${fixture_root}/output/human.json" "${fixture_root}/output/github.json"

prepare_fixture incorrect-account-substitution
fixture_root="${test_root}/incorrect-account-substitution"
template_file="${fixture_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json"
mutated_file="${fixture_root}/mutated.json"
jq --arg wrong_account_id "${wrong_account_id}" '
  (.Statement[] | select(.Sid == "AuditExactBootstrapUser") | .Resource) =
    ("arn:aws:iam::" + $wrong_account_id + ":user/opensearch-lab-bootstrap")
' \
  "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure incorrect-account-substitution "failed its security contract" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" "${state_bucket_name}" \
  "${fixture_root}/output/human.json" "${fixture_root}/output/github.json"

prepare_fixture incorrect-bucket-substitution
fixture_root="${test_root}/incorrect-bucket-substitution"
template_file="${fixture_root}/infra/bootstrap/policies/github-actions-boundary.template.json"
mutated_file="${fixture_root}/mutated.json"
jq '(.Statement[] | select(.Sid == "ReadAndWriteTerraformState") | .Resource) =
  "arn:aws:s3:::wrong-synthetic-bucket/bootstrap/terraform.tfstate"' \
  "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure incorrect-bucket-substitution "failed its security contract" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" "${state_bucket_name}" \
  "${fixture_root}/output/human.json" "${fixture_root}/output/github.json"

prepare_fixture invalid-json
fixture_root="${test_root}/invalid-json"
printf '{ invalid JSON\n' \
  >"${fixture_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json"
expect_failure invalid-json "" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" "${state_bucket_name}" \
  "${fixture_root}/output/human.json" "${fixture_root}/output/github.json"

prepare_fixture incorrect-file-permissions
fixture_root="${test_root}/incorrect-file-permissions"
generator="${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"
perl -0pi -e 's/chmod 0600/chmod 0644/' "${generator}"
expect_failure incorrect-file-permissions "does not have mode 0600" \
  "${generator}" "${account_id}" "${state_bucket_name}" \
  "${fixture_root}/output/human.json" "${fixture_root}/output/github.json"

prepare_fixture bootstrap-user-attachment
fixture_root="${test_root}/bootstrap-user-attachment"
template_file="${fixture_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json"
mutated_file="${fixture_root}/mutated.json"
jq '(.Statement[] | select(.Sid == "AuditExactBootstrapUser") | .Action) +=
  ["iam:AttachUserPolicy"]' "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure bootstrap-user-attachment "failed its security contract" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" "${state_bucket_name}" \
  "${fixture_root}/output/human.json" "${fixture_root}/output/github.json"

prepare_fixture boundary-mutation
fixture_root="${test_root}/boundary-mutation"
template_file="${fixture_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json"
mutated_file="${fixture_root}/mutated.json"
jq '(.Statement[] | select(.Sid == "ReadExactPermissionsBoundaries") | .Action) +=
  ["iam:CreatePolicyVersion"]' "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure boundary-mutation "failed its security contract" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" "${state_bucket_name}" \
  "${fixture_root}/output/human.json" "${fixture_root}/output/github.json"

prepare_fixture service-contract-broadening
fixture_root="${test_root}/service-contract-broadening"
template_file="${fixture_root}/infra/bootstrap/policies/github-actions-boundary.template.json"
mutated_file="${fixture_root}/mutated.json"
jq '(.Statement[] | select(.Sid == "ReadAndWriteTerraformState") | .Action) +=
  ["s3:GetObjectVersion"]' "${template_file}" >"${mutated_file}"
mv "${mutated_file}" "${template_file}"
expect_failure service-contract-broadening "failed its security contract" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${account_id}" "${state_bucket_name}" \
  "${fixture_root}/output/human.json" "${fixture_root}/output/github.json"

expect_contract_mutation \
  allowed-delete-on-state-object \
  terraform-admin-boundary.template.json \
  '(.Statement[] | select(.Sid == "ReadAndWriteTerraformState") | .Action) += ["s3:DeleteObject"]'

expect_contract_mutation \
  admin-action-in-github-boundary \
  github-actions-boundary.template.json \
  '(.Statement[] | select(.Sid == "ReadAndWriteTerraformState") | .Action) += ["iam:GetRole"]'

expect_contract_mutation \
  removed-list-prefix-condition \
  github-actions-boundary.template.json \
  'del(.Statement[] | select(.Sid == "ListExactTerraformStateKeys") | .Condition)'

expect_contract_mutation \
  same-account-wrong-user \
  terraform-admin-boundary.template.json \
  '(.Statement[] | select(.Sid == "AuditExactBootstrapUser") | .Resource) = "arn:aws:iam::__AWS_ACCOUNT_ID__:user/opensearch-lab-other"'

expect_contract_mutation \
  unexpected-statement-key \
  terraform-admin-boundary.template.json \
  '(.Statement[] | select(.Sid == "AuditExactBootstrapUser") | .Principal) = {"AWS": "*"}'

printf 'Permissions-boundary renderer tests passed: %d cases.\n' "${case_count}"
