#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT

mkdir -p \
  "${test_root}/infra/bootstrap/policies" \
  "${test_root}/infra/bootstrap/scripts"
git -C "${test_root}" init -q
cp "${source_root}/.gitignore" "${test_root}/.gitignore"
cp "${source_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
cp "${source_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${test_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"

"${test_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" >/dev/null
resolved_policy="${test_root}/.private/terraform-bootstrap/temporary-bootstrap-policy.json"

test -s "${resolved_policy}"
git -C "${test_root}" check-ignore -q "${resolved_policy}"

if stat -f '%Lp' "${resolved_policy}" >/dev/null 2>&1; then
  file_mode="$(stat -f '%Lp' "${resolved_policy}")"
else
  file_mode="$(stat -c '%a' "${resolved_policy}")"
fi
test "${file_mode}" = "600"

jq -e '
  [.Statement[] | select(.Effect == "Allow")] as $allows
  | ($allows | length) == 10
    and all(
      $allows[];
      .Condition.ArnLike["aws:SignInSessionArn"]
        == "arn:aws:signin:*:${aws:PrincipalAccount}:session/*"
      and (.Condition.DateLessThan["aws:CurrentTime"] | fromdateiso8601) > now
      and ((.Condition.DateLessThan["aws:CurrentTime"] | fromdateiso8601) - now) <= 14400
    )
    and ([$allows[].Condition.DateLessThan["aws:CurrentTime"]] | unique | length == 1)
    and ([.. | objects | keys[] | select(endswith("IfExists"))] | length == 0)
    and ([.. | strings | select(startswith("aws-portal:"))] | length == 0)
    and ([.. | strings | select(. == "iam:CreateServiceLinkedRole")] | length == 0)
    and (
      .Statement[]
      | select(.Sid == "ManageExactBootstrapBudget")
      | .Action | sort
    ) == [
      "budgets:ListTagsForResource",
      "budgets:ModifyBudget",
      "budgets:TagResource",
      "budgets:UntagResource",
      "budgets:ViewBudget"
    ]
    and (
      .Statement[]
      | select(.Sid == "ReadDefaultBillingViewData")
      | .Action == "billing:GetBillingViewData" and .Resource == "*"
    )
' "${resolved_policy}" >/dev/null

test "$(wc -c <"${resolved_policy}" | tr -d '[:space:]')" -le 6144

echo "Temporary policy generation safeguards passed."
