#!/usr/bin/env bash
set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
account_id="$(printf '%06d%06d' 321 654)"
negative_case_count=0

mkdir -p \
  "${test_root}/infra/bootstrap/policies" \
  "${test_root}/infra/bootstrap/scripts"
git -C "${test_root}" init -q
cp "${source_root}/.gitignore" "${test_root}/.gitignore"
cp "${source_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json" \
  "${test_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json"
cp "${source_root}/infra/bootstrap/policies/github-actions-boundary.template.json" \
  "${test_root}/infra/bootstrap/policies/github-actions-boundary.template.json"
cp "${source_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${test_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"
cp "${source_root}/infra/bootstrap/scripts/policy-contract-digest.sh" \
  "${test_root}/infra/bootstrap/scripts/policy-contract-digest.sh"
generator_script="${test_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"

expect_generation_failure() {
  local case_name="$1"
  local expected_diagnostic="$2"
  local supplied_account_id="$3"
  local generation_output

  if generation_output="$(AWS_ACCOUNT_ID="${supplied_account_id}" \
    "${generator_script}" 2>&1)"; then
    echo "Permissions-boundary generation unexpectedly accepted: ${case_name}" >&2
    exit 1
  fi
  if [[ "${generation_output}" != "${expected_diagnostic}" ]]; then
    printf 'Permissions-boundary generation failed with an unexpected diagnostic for %s.\n' \
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

AWS_ACCOUNT_ID="${account_id}" \
  "${generator_script}" >/dev/null

private_dir="${test_root}/.private/terraform-bootstrap"
human_boundary="${private_dir}/terraform-admin-boundary.json"
github_boundary="${private_dir}/github-actions-boundary.json"
state_bucket_name="opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"

if stat -f '%Lp' "${private_dir}" >/dev/null 2>&1; then
  private_mode="$(stat -f '%Lp' "${private_dir}")"
else
  private_mode="$(stat -c '%a' "${private_dir}")"
fi
test "${private_mode}" = "700"

for boundary_file in "${human_boundary}" "${github_boundary}"; do
  test -s "${boundary_file}"
  git -C "${test_root}" check-ignore -q "${boundary_file}"

  if stat -f '%Lp' "${boundary_file}" >/dev/null 2>&1; then
    file_mode="$(stat -f '%Lp' "${boundary_file}")"
  else
    file_mode="$(stat -c '%a' "${boundary_file}")"
  fi
  test "${file_mode}" = "600"
  test "$(wc -c <"${boundary_file}" | tr -d '[:space:]')" -le 6144
done

if ! jq -e --arg account_id "${account_id}" --arg bucket "${state_bucket_name}" '
  def list: if type == "array" then sort else [.] end;
  def statement($sid):
    [.Statement[] | select(.Sid == $sid)]
    | if length == 1 then .[0] else null end;
  def ordinary_keys: (keys | sort) == ["Action", "Effect", "Resource", "Sid"];
  . as $policy
  | $policy.Version == "2012-10-17"
    and ($policy | keys | sort) == ["Statement", "Version"]
    and ($policy.Statement | length) == 12
    and ([$policy.Statement[].Sid] | sort) == [
      "AuditExactBootstrapUser",
      "DeleteReviewedTemporaryBootstrapPolicy",
      "DetachReviewedTemporaryBootstrapPolicy",
      "ListExactTerraformStateKeys",
      "ManageBootstrapBudget",
      "ManageStateBucketControls",
      "ManageTerraformStateLock",
      "ReadAndWriteTerraformState",
      "ReadDefaultBillingViewData",
      "ReadExactBootstrapRoles",
      "ReadExactGitHubOIDCProvider",
      "ReadExactPermissionsBoundaries"
    ]
    and all($policy.Statement[]; .Effect == "Allow")
    and all($policy.Statement[]; has("NotAction") | not)
    and all($policy.Statement[]; has("NotResource") | not)
    and all($policy.Statement[]; (.Action | list | all(.[]; contains("*") | not)))
    and all(
      $policy.Statement[];
      .Sid == "ReadDefaultBillingViewData" or (.Resource | list | all(.[]; . != "*"))
    )
    and ([.. | strings | select(contains("__"))] | length == 0)
    and ($policy | statement("ListExactTerraformStateKeys") |
      (keys | sort) == ["Action", "Condition", "Effect", "Resource", "Sid"]
      and .Action == "s3:ListBucket"
      and .Resource == ("arn:aws:s3:::" + $bucket)
      and (.Condition | keys) == ["StringEquals"]
      and (.Condition.StringEquals | keys) == ["s3:prefix"]
      and (.Condition.StringEquals["s3:prefix"] | sort) == [
        "bootstrap/terraform.tfstate",
        "bootstrap/terraform.tfstate.tflock"
      ])
    and ($policy | statement("ReadAndWriteTerraformState") |
      ordinary_keys
      and (.Action | list) == ["s3:GetObject", "s3:PutObject"]
      and .Resource == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate"))
    and ($policy | statement("ManageTerraformStateLock") |
      ordinary_keys
      and (.Action | list) == ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
      and .Resource == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate.tflock"))
    and ($policy | statement("ManageStateBucketControls") |
      ordinary_keys
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
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketVersioning",
        "s3:PutEncryptionConfiguration",
        "s3:PutLifecycleConfiguration",
        "s3:TagResource",
        "s3:UntagResource"
      ]
      and .Resource == ("arn:aws:s3:::" + $bucket))
    and ($policy | statement("ManageBootstrapBudget") |
      ordinary_keys
      and (.Action | list) == [
        "budgets:ListTagsForResource",
        "budgets:ModifyBudget",
        "budgets:TagResource",
        "budgets:UntagResource",
        "budgets:ViewBudget"
      ]
      and .Resource == ("arn:aws:budgets::" + $account_id + ":budget/opensearch-lab-monthly-cost"))
    and ($policy | statement("ReadDefaultBillingViewData") |
      ordinary_keys
      and .Action == "billing:GetBillingViewData"
      and .Resource == "*")
    and ($policy | statement("ReadExactBootstrapRoles") |
      ordinary_keys
      and (.Action | list) == [
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:ListRoleTags"
      ]
      and (.Resource | list) == [
        "arn:aws:iam::" + $account_id + ":role/opensearch-lab-github-actions",
        "arn:aws:iam::" + $account_id + ":role/opensearch-lab-terraform-admin"
      ])
    and ($policy | statement("ReadExactGitHubOIDCProvider") |
      ordinary_keys
      and (.Action | list) == ["iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviderTags"]
      and .Resource == ("arn:aws:iam::" + $account_id + ":oidc-provider/token.actions.githubusercontent.com"))
    and ($policy | statement("AuditExactBootstrapUser") |
      ordinary_keys
      and (.Action | list) == [
        "iam:GetUser",
        "iam:ListAccessKeys",
        "iam:ListAttachedUserPolicies",
        "iam:ListGroupsForUser",
        "iam:ListMFADevices",
        "iam:ListUserPolicies"
      ]
      and .Resource == ("arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap"))
    and ($policy | statement("ReadExactPermissionsBoundaries") |
      ordinary_keys
      and (.Action | list) == ["iam:GetPolicy", "iam:GetPolicyVersion"]
      and (.Resource | list) == [
        "arn:aws:iam::" + $account_id + ":policy/opensearch-lab-github-actions-boundary",
        "arn:aws:iam::" + $account_id + ":policy/opensearch-lab-terraform-admin-boundary"
      ])
    and ($policy | statement("DetachReviewedTemporaryBootstrapPolicy") |
      (keys | sort) == ["Action", "Condition", "Effect", "Resource", "Sid"]
      and .Action == "iam:DetachUserPolicy"
      and .Resource == ("arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap")
      and (.Condition | keys) == ["ArnEquals"]
      and (.Condition.ArnEquals | keys) == ["iam:PolicyARN"]
      and .Condition.ArnEquals["iam:PolicyARN"]
        == ("arn:aws:iam::" + $account_id + ":policy/opensearch-lab-temporary-bootstrap"))
    and ($policy | statement("DeleteReviewedTemporaryBootstrapPolicy") |
      ordinary_keys
      and (.Action | list) == [
        "iam:DeletePolicy",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:ListEntitiesForPolicy"
      ]
      and .Resource == ("arn:aws:iam::" + $account_id + ":policy/opensearch-lab-temporary-bootstrap"))
' "${human_boundary}" >/dev/null; then
  echo "Terraform administration boundary exact contract failed." >&2
  exit 1
fi

if ! jq -e --arg bucket "${state_bucket_name}" '
  def list: if type == "array" then sort else [.] end;
  def statement($sid):
    [.Statement[] | select(.Sid == $sid)]
    | if length == 1 then .[0] else null end;
  . as $policy
  | $policy.Version == "2012-10-17"
    and ($policy | keys | sort) == ["Statement", "Version"]
    and ($policy.Statement | length) == 3
    and ([$policy.Statement[].Sid] | sort) == [
      "ListExactTerraformStateKeys",
      "ManageTerraformStateLock",
      "ReadAndWriteTerraformState"
    ]
    and all($policy.Statement[]; .Effect == "Allow")
    and all($policy.Statement[]; has("NotAction") | not)
    and all($policy.Statement[]; has("NotResource") | not)
    and all($policy.Statement[]; (.Action | list | all(.[]; contains("*") | not)))
    and all($policy.Statement[]; (.Resource | list | all(.[]; . != "*")))
    and ([.. | strings | select(contains("__"))] | length == 0)
    and ($policy | statement("ListExactTerraformStateKeys") |
      (keys | sort) == ["Action", "Condition", "Effect", "Resource", "Sid"]
      and .Action == "s3:ListBucket"
      and .Resource == ("arn:aws:s3:::" + $bucket)
      and (.Condition | keys) == ["StringEquals"]
      and (.Condition.StringEquals | keys) == ["s3:prefix"]
      and (.Condition.StringEquals["s3:prefix"] | sort) == [
        "bootstrap/terraform.tfstate",
        "bootstrap/terraform.tfstate.tflock"
      ])
    and ($policy | statement("ReadAndWriteTerraformState") |
      (keys | sort) == ["Action", "Effect", "Resource", "Sid"]
      and (.Action | list) == ["s3:GetObject", "s3:PutObject"]
      and .Resource == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate"))
    and ($policy | statement("ManageTerraformStateLock") |
      (keys | sort) == ["Action", "Effect", "Resource", "Sid"]
      and (.Action | list) == ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
      and .Resource == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate.tflock"))
' "${github_boundary}" >/dev/null; then
  echo "GitHub Actions boundary exact contract failed." >&2
  exit 1
fi

mutated_template="${test_root}/infra/bootstrap/policies/github-actions-boundary.template.json.mutated"
jq '.Statement[0].Action = "iam:PutRolePermissionsBoundary"' \
  "${test_root}/infra/bootstrap/policies/github-actions-boundary.template.json" \
  >"${mutated_template}"
mv "${mutated_template}" \
  "${test_root}/infra/bootstrap/policies/github-actions-boundary.template.json"
jq -e '.Statement[0].Action == "iam:PutRolePermissionsBoundary"' \
  "${test_root}/infra/bootstrap/policies/github-actions-boundary.template.json" >/dev/null
expect_generation_failure \
  "boundary-mutation-permission" \
  "A permissions-boundary template differs from its exact reviewed contract." \
  "${account_id}"

printf 'Permissions boundary generation safeguards passed (%d negative cases).\n' \
  "${negative_case_count}"
