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
policy_dir="${repository_root}/infra/bootstrap/policies"
private_dir="${repository_root}/.private/terraform-bootstrap"
partition="aws"
state_bucket_name="opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"
human_template_digest="ad115920994021f6d73f337c1744223458279a282f53ed9d6e516e85c65a040d"
github_template_digest="21a1c3d24734eceb43fa2b0dd69f0748a89e480b5e20fcb41dd04ffa72e6f8b7"

if [[ ! -x "${contract_digest_script}" ]]; then
  echo "The policy-contract digest helper is unavailable." >&2
  exit 1
fi
if [[ "$("${contract_digest_script}" "${policy_dir}/terraform-admin-boundary.template.json")" != \
  "${human_template_digest}" ]] || \
  [[ "$("${contract_digest_script}" "${policy_dir}/github-actions-boundary.template.json")" != \
  "${github_template_digest}" ]]; then
  echo "A permissions-boundary template differs from its exact reviewed contract." >&2
  exit 1
fi

mkdir -p "${private_dir}"
chmod 700 "${private_dir}"
umask 077

human_temporary="$(mktemp "${private_dir}/terraform-admin-boundary.json.XXXXXX")"
github_temporary="$(mktemp "${private_dir}/github-actions-boundary.json.XXXXXX")"
trap 'rm -f -- "${human_temporary}" "${github_temporary}"' EXIT

resolve_template() {
  local template_file="$1"
  local output_file="$2"

  jq -ce \
    --arg account_id "${account_id}" \
    --arg partition "${partition}" \
    --arg state_bucket_name "${state_bucket_name}" '
      walk(
        if type == "string" then
          gsub("__AWS_ACCOUNT_ID__"; $account_id)
          | gsub("__AWS_PARTITION__"; $partition)
          | gsub("__STATE_BUCKET_NAME__"; $state_bucket_name)
        else
          .
        end
      )
    ' "${template_file}" >"${output_file}"
}

resolve_template \
  "${policy_dir}/terraform-admin-boundary.template.json" \
  "${human_temporary}"
resolve_template \
  "${policy_dir}/github-actions-boundary.template.json" \
  "${github_temporary}"

for resolved_file in "${human_temporary}" "${github_temporary}"; do
  if ! jq -e '
    [.. | strings | select(contains("__"))] | length == 0
  ' "${resolved_file}" >/dev/null; then
    echo "A resolved permissions boundary still contains a template sentinel." >&2
    exit 1
  fi

  if ! jq -e '
    all(.Statement[]; .Effect == "Allow")
    and ([.. | objects | select(has("NotAction") or has("NotResource"))] | length == 0)
  ' "${resolved_file}" >/dev/null; then
    echo "A permissions boundary contains an unsupported policy form." >&2
    exit 1
  fi

  if ! jq -e '
    def actions: .Action | if type == "array" then . else [.] end;
    def forbidden_boundary_mutations: [
      "iam:AttachRolePolicy",
      "iam:AttachUserPolicy",
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary",
      "iam:DetachRolePolicy",
      "iam:PutRolePermissionsBoundary",
      "iam:PutUserPermissionsBoundary",
      "iam:SetDefaultPolicyVersion",
      "iam:TagPolicy",
      "iam:UntagPolicy"
    ];
    ([.Statement[] | actions[]] - forbidden_boundary_mutations | length)
      == ([.Statement[] | actions[]] | length)
    and ([
      .Statement[]
      | select((.Resource | tojson | contains("-boundary")))
      | actions[]
      | select(. != "iam:GetPolicy" and . != "iam:GetPolicyVersion")
    ] | length == 0)
  ' "${resolved_file}" >/dev/null; then
    echo "A boundary policy permits mutation of a permissions boundary." >&2
    exit 1
  fi

  compact_size="$(wc -c <"${resolved_file}" | tr -d '[:space:]')"
  if ((compact_size > 6144)); then
    echo "A resolved permissions boundary exceeds the managed-policy size limit." >&2
    exit 1
  fi
  chmod 600 "${resolved_file}"
done

mv "${human_temporary}" "${private_dir}/terraform-admin-boundary.json"
mv "${github_temporary}" "${private_dir}/github-actions-boundary.json"
trap - EXIT

echo "Permissions boundaries generated in the private bootstrap directory."
