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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
template_file="${repository_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
private_dir="${repository_root}/.private/terraform-bootstrap"
output_file="${private_dir}/temporary-bootstrap-policy.json"
expiry_sentinel="__TEMPORARY_POLICY_EXPIRY_UTC__"
sign_in_pattern="arn:aws:signin:*:\${aws:PrincipalAccount}:session/*"

mkdir -p "${private_dir}"
chmod 700 "${private_dir}"
umask 077

if ! jq -e \
  --arg expiry_sentinel "${expiry_sentinel}" \
  --arg sign_in_pattern "${sign_in_pattern}" '
    [.Statement[] | select(.Effect == "Allow")] as $allows
    | ($allows | length) > 0
      and all(
        $allows[];
        .Condition.ArnLike["aws:SignInSessionArn"] == $sign_in_pattern
        and .Condition.DateLessThan["aws:CurrentTime"] == $expiry_sentinel
      )
      and ([.. | objects | keys[] | select(endswith("IfExists"))] | length == 0)
      and ([.. | strings | select(startswith("aws-portal:"))] | length == 0)
      and ([.. | strings | select(. == "iam:CreateServiceLinkedRole")] | length == 0)
  ' "${template_file}" >/dev/null; then
  echo "The temporary policy template failed its security invariants." >&2
  exit 1
fi

expiry="$(jq -nr 'now | floor | . + 14400 | todateiso8601')"
temporary_file="$(mktemp "${private_dir}/temporary-bootstrap-policy.json.XXXXXX")"
trap 'rm -f -- "${temporary_file}"' EXIT

jq -ce --arg expiry "${expiry}" '
  (.Statement[] | select(.Effect == "Allow") | .Condition.DateLessThan["aws:CurrentTime"]) = $expiry
' "${template_file}" >"${temporary_file}"

compact_size="$(wc -c <"${temporary_file}" | tr -d '[:space:]')"
if ((compact_size > 6144)); then
  echo "The resolved policy exceeds the IAM managed-policy size limit." >&2
  exit 1
fi

if grep -Fq "${expiry_sentinel}" "${temporary_file}"; then
  echo "The resolved policy still contains its expiry sentinel." >&2
  exit 1
fi

chmod 600 "${temporary_file}"
mv "${temporary_file}" "${output_file}"
trap - EXIT

echo "Temporary bootstrap policy generated with a four-hour UTC expiry."
