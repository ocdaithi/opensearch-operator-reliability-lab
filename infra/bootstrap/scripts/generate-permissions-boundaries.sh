#!/usr/bin/env bash
set -euo pipefail

if (($# != 0)); then
  echo "This command does not accept arguments." >&2
  exit 1
fi

for command_name in git jq link mktemp; do
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
human_destination="${private_dir}/terraform-admin-boundary.json"
github_destination="${private_dir}/github-actions-boundary.json"
lock_directory="${private_dir}/.generate-permissions-boundaries.lock"
partition="aws"
state_bucket_name="opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"
billing_view_arn="arn:${partition}:billing::${account_id}:billingview/primary"
human_template_digest="c8592acc57fea897687b8b9b12cba677d9411f47b5c92280c3576f57846ff906"
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

human_temporary=""
github_temporary=""
lock_owned=false

cleanup() {
  local exit_status="$?"

  trap - EXIT HUP INT TERM

  if [[ -n "${human_temporary}" ]]; then
    rm -f -- "${human_temporary}"
  fi
  if [[ -n "${github_temporary}" ]]; then
    rm -f -- "${github_temporary}"
  fi
  if [[ "${lock_owned}" == true ]]; then
    rmdir "${lock_directory}" >/dev/null 2>&1 || true
  fi

  exit "${exit_status}"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if ! mkdir "${lock_directory}" 2>/dev/null; then
  echo "Another permissions-boundary generation is active or its lock remains." >&2
  exit 1
fi
lock_owned=true

destination_must_not_exist() {
  local destination="$1"

  if [[ -e "${destination}" || -L "${destination}" ]]; then
    echo "Refusing to overwrite existing destination: ${destination}" >&2
    return 1
  fi
}

publish_exclusively() {
  local staged_file="$1"
  local destination="$2"

  if ! link "${staged_file}" "${destination}" 2>/dev/null; then
    echo "Could not publish without overwriting destination: ${destination}" >&2
    return 1
  fi
}

destination_must_not_exist "${human_destination}"
destination_must_not_exist "${github_destination}"

human_temporary="$(mktemp "${private_dir}/.terraform-admin-boundary.json.XXXXXX")"
github_temporary="$(mktemp "${private_dir}/.github-actions-boundary.json.XXXXXX")"

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

if ! jq -e --arg billing_view_arn "${billing_view_arn}" '
  [.Statement[] | select(.Sid == "ReadDefaultBillingViewData")]
  | length == 1
    and .[0].Action == "billing:GetBillingViewData"
    and .[0].Resource == $billing_view_arn
' "${human_temporary}" >/dev/null; then
  echo "The Terraform administration boundary failed its billing-view invariant." >&2
  exit 1
fi

destination_must_not_exist "${human_destination}"
destination_must_not_exist "${github_destination}"

publish_exclusively "${human_temporary}" "${human_destination}"
publish_exclusively "${github_temporary}" "${github_destination}"

echo "Permissions boundaries generated in the private bootstrap directory."
