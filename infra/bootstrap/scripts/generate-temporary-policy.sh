#!/usr/bin/env bash

set -euo pipefail

if (($# != 0)); then
  echo "This command does not accept arguments." >&2
  exit 1
fi

for command_name in git jq mktemp; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${command_name}" >&2
    exit 1
  fi
done

account_id="${AWS_ACCOUNT_ID:-}"
if [[ ! "${account_id}" =~ ^[0-9]{12}$ ]]; then
  echo "AWS_ACCOUNT_ID must contain exactly 12 digits." >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
contract_digest_script="${script_dir}/policy-contract-digest.sh"
template_file="${repository_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
private_dir="${repository_root}/.private/terraform-bootstrap"
output_file="${private_dir}/temporary-bootstrap-policy.json"
expiry_sentinel="__TEMPORARY_POLICY_EXPIRY_UTC__"
account_sentinel="__AWS_ACCOUNT_ID__"
bucket_sentinel="__STATE_BUCKET_NAME__"
state_bucket_name="opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"
sign_in_pattern="arn:aws:signin:*:\${aws:PrincipalAccount}:session/*"
reviewed_template_digest="856ce1b87222cbb03b66085339670195f756591d652b3a4a2a134a3121aa9b3a"

if [[ ! -x "${contract_digest_script}" ]]; then
  echo "The policy-contract digest helper is unavailable." >&2
  exit 1
fi
if [[ "$("${contract_digest_script}" "${template_file}")" != \
  "${reviewed_template_digest}" ]]; then
  echo "The temporary policy template differs from its exact reviewed contract." >&2
  exit 1
fi

mkdir -p "${private_dir}"
chmod 700 "${private_dir}"
umask 077

if ! jq -e \
  --arg expiry_sentinel "${expiry_sentinel}" \
  --arg account_sentinel "${account_sentinel}" \
  --arg bucket_sentinel "${bucket_sentinel}" \
  --arg sign_in_pattern "${sign_in_pattern}" '
    def actions: .Action | if type == "array" then . else [.] end;
    def forbidden_boundary_actions: [
      "iam:AttachRolePolicy",
      "iam:AttachUserPolicy",
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
      "iam:DetachRolePolicy",
      "iam:DetachUserPolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:PutUserPermissionsBoundary",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy"
    ];
    [.Statement[] | select(.Effect == "Allow")] as $allows
    | .Version == "2012-10-17"
      and (keys | sort) == ["Statement", "Version"]
      and (.Statement | length) == 12
      and ($allows | length) == (.Statement | length)
      and all(
        $allows[];
        (has("NotAction") | not)
        and (has("NotResource") | not)
        and
        .Condition.ArnLike["aws:SignInSessionArn"] == $sign_in_pattern
        and .Condition.DateLessThan["aws:CurrentTime"] == $expiry_sentinel
      )
      and ([.. | objects | keys[] | select(endswith("IfExists"))] | length == 0)
      and ([.. | strings | select(startswith("aws-portal:"))] | length == 0)
      and ([.. | strings | select(. == "iam:CreateServiceLinkedRole")] | length == 0)
      and ([.. | strings | select(contains($account_sentinel))] | length > 0)
      and ([.. | strings | select(contains($bucket_sentinel))] | length > 0)
      and (([.Statement[] | actions[]] - forbidden_boundary_actions | length)
        == ([.Statement[] | actions[]] | length))
      and (
        .Statement[]
        | select(.Sid == "CreateHumanRoleWithBoundary")
        | .Condition.ArnEquals["iam:PermissionsBoundary"]
          == ("arn:aws:iam::" + $account_sentinel + ":policy/opensearch-lab-terraform-admin-boundary")
      )
      and (
        .Statement[]
        | select(.Sid == "CreateGitHubRoleWithBoundary")
        | .Condition.ArnEquals["iam:PermissionsBoundary"]
          == ("arn:aws:iam::" + $account_sentinel + ":policy/opensearch-lab-github-actions-boundary")
      )
  ' "${template_file}" >/dev/null; then
  echo "The temporary policy template failed its security invariants." >&2
  exit 1
fi

expiry="$(jq -nr 'now | floor | . + 14400 | todateiso8601')"
temporary_file="$(mktemp "${private_dir}/temporary-bootstrap-policy.json.XXXXXX")"
trap 'rm -f -- "${temporary_file}"' EXIT

jq -ce \
  --arg account_id "${account_id}" \
  --arg expiry "${expiry}" \
  --arg state_bucket_name "${state_bucket_name}" '
  (.Statement[] | select(.Effect == "Allow") | .Condition.DateLessThan["aws:CurrentTime"]) = $expiry
  | walk(
      if type == "string" then
        gsub("__AWS_ACCOUNT_ID__"; $account_id)
        | gsub("__STATE_BUCKET_NAME__"; $state_bucket_name)
      else
        .
      end
    )
' "${template_file}" >"${temporary_file}"

compact_size="$(wc -c <"${temporary_file}" | tr -d '[:space:]')"
if ((compact_size > 6144)); then
  echo "The resolved policy exceeds the IAM managed-policy size limit." >&2
  exit 1
fi

if grep -Eq '__[A-Z0-9_]+__' "${temporary_file}"; then
  echo "The resolved policy still contains a template sentinel." >&2
  exit 1
fi

chmod 600 "${temporary_file}"
mv "${temporary_file}" "${output_file}"
trap - EXIT

echo "Temporary bootstrap policy generated with a four-hour UTC expiry."
