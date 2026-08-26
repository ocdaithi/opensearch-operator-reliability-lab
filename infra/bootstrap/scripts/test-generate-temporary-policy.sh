#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
account_id="$(printf '%06d%06d' 123 789)"
negative_case_count=0

mkdir -p \
  "${test_root}/infra/bootstrap/policies" \
  "${test_root}/infra/bootstrap/scripts"
git -C "${test_root}" init -q
cp "${source_root}/.gitignore" "${test_root}/.gitignore"
cp "${source_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
cp "${source_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${test_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"
cp "${source_root}/infra/bootstrap/scripts/policy-contract-digest.sh" \
  "${test_root}/infra/bootstrap/scripts/policy-contract-digest.sh"
generator_script="${test_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"

expect_generation_failure() {
  local case_name="$1"
  local expected_diagnostic="$2"
  local supplied_account_id="$3"
  local generation_output

  if generation_output="$(AWS_ACCOUNT_ID="${supplied_account_id}" \
    "${generator_script}" 2>&1)"; then
    echo "Temporary policy generation unexpectedly accepted: ${case_name}" >&2
    exit 1
  fi
  if [[ "${generation_output}" != "${expected_diagnostic}" ]]; then
    printf 'Temporary policy generation failed with an unexpected diagnostic for %s.\n' \
      "${case_name}" >&2
    printf 'Expected: %s\n' "${expected_diagnostic}" >&2
    printf 'Actual: %s\n' "${generation_output:-<no output>}" >&2
    exit 1
  fi
  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: %s\n' "${case_name}"
}

expect_generation_failure \
  "missing-account-id" \
  "AWS_ACCOUNT_ID must contain exactly 12 digits." \
  ""

generation_started="$(date -u +%s)"
AWS_ACCOUNT_ID="${account_id}" \
  "${generator_script}" >/dev/null
generation_finished="$(date -u +%s)"
resolved_policy="${test_root}/.private/terraform-bootstrap/temporary-bootstrap-policy.json"
state_bucket_name="opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"
minimum_expiry=$((generation_started + 14395))
maximum_expiry=$((generation_finished + 14405))

test -s "${resolved_policy}"
git -C "${test_root}" check-ignore -q "${resolved_policy}"

if stat -f '%Lp' "${resolved_policy}" >/dev/null 2>&1; then
  file_mode="$(stat -f '%Lp' "${resolved_policy}")"
else
  file_mode="$(stat -c '%a' "${resolved_policy}")"
fi
test "${file_mode}" = "600"

if ! jq -e \
  --arg account_id "${account_id}" \
  --arg bucket "${state_bucket_name}" \
  --argjson minimum_expiry "${minimum_expiry}" \
  --argjson maximum_expiry "${maximum_expiry}" '
  def list: if type == "array" then sort else [.] end;
  def statement($sid):
    [.Statement[] | select(.Sid == $sid)]
    | if length == 1 then .[0] else null end;
  def common_condition:
    .Condition.ArnLike["aws:SignInSessionArn"]
      == "arn:aws:signin:*:${aws:PrincipalAccount}:session/*"
    and (.Condition.DateLessThan["aws:CurrentTime"] | fromdateiso8601) >= $minimum_expiry
    and (.Condition.DateLessThan["aws:CurrentTime"] | fromdateiso8601) <= $maximum_expiry;
  def common_keys:
    (keys | sort) == ["Action", "Condition", "Effect", "Resource", "Sid"]
    and (.Condition | keys | sort) == ["ArnLike", "DateLessThan"];
  . as $policy
  | [.Statement[] | select(.Effect == "Allow")] as $allows
  | $policy.Version == "2012-10-17"
    and ($policy | keys | sort) == ["Statement", "Version"]
    and ($policy.Statement | length) == 12
    and ($allows | length) == 12
    and ([$allows[].Sid] | sort) == [
      "CreateAndTagExactStateBucket",
      "CreateGitHubRoleWithBoundary",
      "CreateHumanRoleWithBoundary",
      "ListExactTerraformStateKeys",
      "ManageExactBootstrapBudget",
      "ManageExactGitHubOIDCProvider",
      "ManageStateBucketControls",
      "ManageTerraformStateLock",
      "ReadAndTagExactBootstrapRoles",
      "ReadAndWriteTerraformState",
      "ReadDefaultBillingViewData",
      "ReadExactBootstrapUser"
    ]
    and all($allows[]; common_condition)
    and ([$allows[].Condition.DateLessThan["aws:CurrentTime"]] | unique | length == 1)
    and all($allows[]; has("NotAction") | not)
    and all($allows[]; has("NotResource") | not)
    and all($allows[]; (.Action | list | all(.[]; contains("*") | not)))
    and all(
      $allows[];
      .Sid == "ReadDefaultBillingViewData" or (.Resource | list | all(.[]; . != "*"))
    )
    and ([.. | objects | keys[] | select(endswith("IfExists"))] | length == 0)
    and ([.. | strings | select(startswith("aws-portal:"))] | length == 0)
    and ([.. | strings | select(. == "iam:CreateServiceLinkedRole")] | length == 0)
    and ([.. | strings | select(contains("__"))] | length == 0)
    and ($policy | statement("CreateAndTagExactStateBucket") |
      common_keys
      and (.Action | list) == ["s3:CreateBucket", "s3:TagResource"]
      and .Resource == ("arn:aws:s3:::" + $bucket))
    and ($policy | statement("ManageStateBucketControls") |
      common_keys
      and (.Action | list) == [
        "s3:GetAccelerateConfiguration",
        "s3:GetBucketAcl",
        "s3:GetBucketCORS",
        "s3:GetBucketLocation",
        "s3:GetBucketLogging",
        "s3:GetBucketObjectLockConfiguration",
        "s3:GetBucketOwnershipControls",
        "s3:GetBucketPolicy",
        "s3:GetBucketPublicAccessBlock",
        "s3:GetBucketRequestPayment",
        "s3:GetBucketVersioning",
        "s3:GetBucketWebsite",
        "s3:GetEncryptionConfiguration",
        "s3:GetLifecycleConfiguration",
        "s3:GetReplicationConfiguration",
        "s3:ListBucket",
        "s3:ListTagsForResource",
        "s3:PutBucketOwnershipControls",
        "s3:PutBucketPolicy",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketVersioning",
        "s3:PutEncryptionConfiguration",
        "s3:PutLifecycleConfiguration",
        "s3:UntagResource"
      ]
      and .Resource == ("arn:aws:s3:::" + $bucket))
    and ($policy | statement("ListExactTerraformStateKeys") |
      (keys | sort) == ["Action", "Condition", "Effect", "Resource", "Sid"]
      and (.Condition | keys | sort) == ["ArnLike", "DateLessThan", "StringEquals"]
      and (.Condition.StringEquals | keys) == ["s3:prefix"]
      and .Action == "s3:ListBucket"
      and .Resource == ("arn:aws:s3:::" + $bucket)
      and (.Condition.StringEquals["s3:prefix"] | sort) == [
        "bootstrap/terraform.tfstate",
        "bootstrap/terraform.tfstate.tflock"
      ])
    and ($policy | statement("ReadAndWriteTerraformState") |
      common_keys
      and (.Action | list) == ["s3:GetObject", "s3:PutObject"]
      and .Resource == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate"))
    and ($policy | statement("ManageTerraformStateLock") |
      common_keys
      and (.Action | list) == ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
      and .Resource == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate.tflock"))
    and ($policy | statement("ManageExactBootstrapBudget") |
      common_keys
      and (.Action | list) == [
        "budgets:ListTagsForResource",
        "budgets:ModifyBudget",
        "budgets:TagResource",
        "budgets:UntagResource",
        "budgets:ViewBudget"
      ]
      and .Resource == ("arn:aws:budgets::" + $account_id + ":budget/opensearch-lab-monthly-cost"))
    and ($policy | statement("ReadDefaultBillingViewData") |
      common_keys
      and .Action == "billing:GetBillingViewData"
      and .Resource == "*")
    and ($policy | statement("CreateHumanRoleWithBoundary") |
      (keys | sort) == ["Action", "Condition", "Effect", "Resource", "Sid"]
      and (.Condition | keys | sort) == ["ArnEquals", "ArnLike", "DateLessThan"]
      and (.Condition.ArnEquals | keys) == ["iam:PermissionsBoundary"]
      and (.Action | list) == ["iam:CreateRole", "iam:PutRolePolicy"]
      and .Resource == ("arn:aws:iam::" + $account_id + ":role/opensearch-lab-terraform-admin")
      and .Condition.ArnEquals["iam:PermissionsBoundary"]
        == ("arn:aws:iam::" + $account_id + ":policy/opensearch-lab-terraform-admin-boundary"))
    and ($policy | statement("CreateGitHubRoleWithBoundary") |
      (keys | sort) == ["Action", "Condition", "Effect", "Resource", "Sid"]
      and (.Condition | keys | sort) == ["ArnEquals", "ArnLike", "DateLessThan"]
      and (.Condition.ArnEquals | keys) == ["iam:PermissionsBoundary"]
      and (.Action | list) == ["iam:CreateRole", "iam:PutRolePolicy"]
      and .Resource == ("arn:aws:iam::" + $account_id + ":role/opensearch-lab-github-actions")
      and .Condition.ArnEquals["iam:PermissionsBoundary"]
        == ("arn:aws:iam::" + $account_id + ":policy/opensearch-lab-github-actions-boundary"))
    and ($policy | statement("ReadAndTagExactBootstrapRoles") |
      common_keys
      and (.Action | list) == [
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:ListRoleTags",
        "iam:TagRole"
      ]
      and (.Resource | list) == [
        "arn:aws:iam::" + $account_id + ":role/opensearch-lab-github-actions",
        "arn:aws:iam::" + $account_id + ":role/opensearch-lab-terraform-admin"
      ])
    and ($policy | statement("ManageExactGitHubOIDCProvider") |
      common_keys
      and (.Action | list) == [
        "iam:CreateOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider",
        "iam:ListOpenIDConnectProviderTags",
        "iam:TagOpenIDConnectProvider"
      ]
      and .Resource == ("arn:aws:iam::" + $account_id + ":oidc-provider/token.actions.githubusercontent.com"))
    and ($policy | statement("ReadExactBootstrapUser") |
      common_keys
      and .Action == "iam:GetUser"
      and .Resource == ("arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap"))
' "${resolved_policy}" >/dev/null; then
  echo "Temporary policy exact contract failed." >&2
  exit 1
fi

test "$(wc -c <"${resolved_policy}" | tr -d '[:space:]')" -le 6144

pristine_template="${test_root}/temporary-bootstrap-policy.pristine.json"
cp "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" \
  "${pristine_template}"

mutated_template="${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json.mutated"
jq '.Statement += [{
  "Sid": "UnexpectedDeny",
  "Effect": "Deny",
  "NotAction": "iam:GetUser",
  "NotResource": "arn:aws:iam::__AWS_ACCOUNT_ID__:user/opensearch-lab-bootstrap"
}]' "${pristine_template}" >"${mutated_template}"
mv "${mutated_template}" \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
jq -e 'any(.Statement[]; .Sid == "UnexpectedDeny" and has("NotAction") and has("NotResource"))' \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" >/dev/null
expect_generation_failure \
  "unexpected-deny-statement" \
  "The temporary policy template differs from its exact reviewed contract." \
  "${account_id}"

cp "${pristine_template}" \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
mutated_template="${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json.mutated"
jq '.Statement[0].Action += ["iam:PutRolePermissionsBoundary"]' \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" \
  >"${mutated_template}"
mv "${mutated_template}" \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
jq -e '.Statement[0].Action | index("iam:PutRolePermissionsBoundary") != null' \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" >/dev/null
expect_generation_failure \
  "boundary-mutation-permission" \
  "The temporary policy template differs from its exact reviewed contract." \
  "${account_id}"

printf 'Temporary policy generation safeguards passed (%d negative cases).\n' \
  "${negative_case_count}"
