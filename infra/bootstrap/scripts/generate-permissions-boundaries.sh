#!/usr/bin/env bash
set -euo pipefail

if (($# != 4)); then
  echo "Usage: $0 <aws-account-id> <state-bucket-name> <terraform-admin-output> <github-actions-output>" >&2
  exit 1
fi

for command_name in jq link mktemp; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${command_name}" >&2
    exit 1
  fi
done

account_id="$1"
state_bucket_name="$2"
terraform_admin_output="$3"
github_actions_output="$4"

if [[ ! "${account_id}" =~ ^[0-9]{12}$ ]]; then
  echo "AWS account ID must contain exactly 12 digits." >&2
  exit 1
fi

valid_bucket_name() {
  local bucket_name="$1"

  ((${#bucket_name} >= 3 && ${#bucket_name} <= 63)) &&
    [[ "${bucket_name}" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]] &&
    [[ "${bucket_name}" != *..* && "${bucket_name}" != *.-* && "${bucket_name}" != *-.* ]] &&
    [[ ! "${bucket_name}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] &&
    [[ "${bucket_name}" != xn--* && "${bucket_name}" != sthree-* ]] &&
    [[ "${bucket_name}" != amzn-s3-demo-* && "${bucket_name}" != *-s3alias ]] &&
    [[ "${bucket_name}" != *--ol-s3 && "${bucket_name}" != *.mrap ]] &&
    [[ "${bucket_name}" != *--x-s3 && "${bucket_name}" != *--table-s3 ]]
}

if ! valid_bucket_name "${state_bucket_name}"; then
  echo "State bucket name is not a valid exact S3 bucket name." >&2
  exit 1
fi
if [[ "${terraform_admin_output}" == "${github_actions_output}" ]]; then
  echo "Permissions boundaries require two distinct output paths." >&2
  exit 1
fi

validate_destination() {
  local destination="$1"
  local parent_directory

  if [[ -L "${destination}" ]]; then
    echo "Refusing symlink destination: ${destination}" >&2
    return 1
  fi
  if [[ -e "${destination}" ]]; then
    echo "Refusing to overwrite existing destination: ${destination}" >&2
    return 1
  fi
  parent_directory="$(dirname -- "${destination}")"
  if [[ ! -d "${parent_directory}" ]]; then
    echo "Output directory does not exist: ${parent_directory}" >&2
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

validate_destination "${terraform_admin_output}"
validate_destination "${github_actions_output}"

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
terraform_admin_template="${script_directory}/../policies/terraform-admin-boundary.template.json"
github_actions_template="${script_directory}/../policies/github-actions-boundary.template.json"
for template_file in "${terraform_admin_template}" "${github_actions_template}"; do
  if [[ ! -r "${template_file}" || ! -f "${template_file}" ]]; then
    echo "Policy template is unavailable: ${template_file}" >&2
    exit 1
  fi
done

umask 077
terraform_admin_temporary=""
github_actions_temporary=""
cleanup() {
  local exit_status="$?"

  trap - EXIT HUP INT TERM
  [[ -z "${terraform_admin_temporary}" ]] || rm -f -- "${terraform_admin_temporary}"
  [[ -z "${github_actions_temporary}" ]] || rm -f -- "${github_actions_temporary}"
  exit "${exit_status}"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

terraform_admin_temporary="$(mktemp "${terraform_admin_output}.tmp.XXXXXX")"
github_actions_temporary="$(mktemp "${github_actions_output}.tmp.XXXXXX")"

render_template() {
  local template_file="$1"
  local resolved_file="$2"

  jq -ce \
    --arg account_id "${account_id}" \
    --arg bucket "${state_bucket_name}" '
      walk(
        if type == "string" then
          gsub("__AWS_ACCOUNT_ID__"; $account_id)
          | gsub("__AWS_PARTITION__"; "aws")
          | gsub("__STATE_BUCKET_NAME__"; $bucket)
        else . end
      )
    ' "${template_file}" >"${resolved_file}"

  if grep -Eq '__[A-Z0-9_]+__' "${resolved_file}"; then
    echo "Resolved policy still contains a template placeholder." >&2
    return 1
  fi
  if ! jq -e 'type == "object"' "${resolved_file}" >/dev/null; then
    echo "Resolved policy is not valid JSON." >&2
    return 1
  fi
}

render_template "${terraform_admin_template}" "${terraform_admin_temporary}"
render_template "${github_actions_template}" "${github_actions_temporary}"

validate_boundary() {
  local resolved_file="$1"
  local policy_name="$2"

  if ! jq -e \
    --arg account_id "${account_id}" \
    --arg bucket "${state_bucket_name}" '
      def list: if type == "array" then . else [.] end;
      def actions: [.Statement[] | .Action | list[]];
      def resources: [.Statement[] | .Resource | list[]];
      [
        "billing:GetBillingViewData",
        "budgets:ListTagsForResource", "budgets:ModifyBudget",
        "budgets:TagResource", "budgets:UntagResource", "budgets:ViewBudget",
        "iam:DeletePolicy", "iam:DetachUserPolicy", "iam:GetOpenIDConnectProvider",
        "iam:GetPolicy", "iam:GetPolicyVersion", "iam:GetRole", "iam:GetRolePolicy",
        "iam:GetUser", "iam:ListAccessKeys", "iam:ListAttachedRolePolicies",
        "iam:ListAttachedUserPolicies", "iam:ListEntitiesForPolicy",
        "iam:ListGroupsForUser", "iam:ListMFADevices",
        "iam:ListOpenIDConnectProviderTags", "iam:ListRolePolicies",
        "iam:ListRoleTags", "iam:ListUserPolicies",
        "s3:DeleteObject", "s3:GetAccelerateConfiguration", "s3:GetBucketAcl",
        "s3:GetBucketCORS", "s3:GetBucketLocation", "s3:GetBucketLogging",
        "s3:GetBucketObjectLockConfiguration", "s3:GetBucketOwnershipControls",
        "s3:GetBucketPolicy", "s3:GetBucketPublicAccessBlock",
        "s3:GetBucketRequestPayment", "s3:GetBucketVersioning",
        "s3:GetBucketWebsite", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration",
        "s3:GetObject", "s3:GetReplicationConfiguration", "s3:ListBucket",
        "s3:ListTagsForResource", "s3:PutBucketOwnershipControls",
        "s3:PutBucketPublicAccessBlock", "s3:PutBucketVersioning",
        "s3:PutEncryptionConfiguration", "s3:PutLifecycleConfiguration",
        "s3:PutObject", "s3:TagResource", "s3:UntagResource"
      ] as $allowed_actions
      | . as $policy
      | ($policy | actions) as $actions
      | ($policy | resources) as $resources
      | ("arn:aws:s3:::" + $bucket) as $bucket_arn
      | $policy.Version == "2012-10-17"
        and ($policy.Statement | type == "array" and length > 0)
        and all($policy.Statement[]; .Effect == "Allow")
        and all($policy.Statement[]; has("Action") and has("Resource"))
        and ([.. | objects | select(has("NotAction") or has("NotResource"))] | length == 0)
        and ($actions - $allowed_actions | length) == 0
        and all($actions[]; type == "string" and (contains("*") | not))
        and all($resources[]; type == "string" and (contains("*") | not))
        and all(
          $resources[];
          if startswith("arn:aws:s3:::") then
            . == $bucket_arn
            or . == ($bucket_arn + "/bootstrap/terraform.tfstate")
            or . == ($bucket_arn + "/bootstrap/terraform.tfstate.tflock")
          elif startswith("arn:aws:iam::") then
            startswith("arn:aws:iam::" + $account_id + ":")
          elif startswith("arn:aws:budgets::") then
            startswith("arn:aws:budgets::" + $account_id + ":")
          elif startswith("arn:aws:billing::") then
            startswith("arn:aws:billing::" + $account_id + ":")
          else false end
        )
        and all(
          $policy.Statement[];
          ([.Resource | list[] | select(endswith("-boundary"))] | length) == 0
          or all(.Action | list[]; . == "iam:GetPolicy" or . == "iam:GetPolicyVersion")
        )
        and ($actions | index("iam:AttachUserPolicy")) == null
        and ($actions | index("iam:PutUserPermissionsBoundary")) == null
        and ($actions | index("iam:PutRolePermissionsBoundary")) == null
        and ([
          .. | objects | select(has("s3:prefix")) | .["s3:prefix"] | list[]
          | select(. != "bootstrap/terraform.tfstate"
            and . != "bootstrap/terraform.tfstate.tflock")
        ] | length) == 0
    ' "${resolved_file}" >/dev/null; then
    echo "${policy_name} failed its security contract." >&2
    return 1
  fi
}

validate_boundary "${terraform_admin_temporary}" "Terraform administration boundary"
validate_boundary "${github_actions_temporary}" "GitHub Actions boundary"

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

for resolved_file in "${terraform_admin_temporary}" "${github_actions_temporary}"; do
  if (($(wc -c <"${resolved_file}") > 6144)); then
    echo "Resolved permissions boundary exceeds the IAM managed-policy size limit." >&2
    exit 1
  fi
  chmod 0600 "${resolved_file}"
  if [[ "$(file_mode "${resolved_file}")" != "600" ]]; then
    echo "Resolved permissions boundary does not have mode 0600." >&2
    exit 1
  fi
done

validate_destination "${terraform_admin_output}"
validate_destination "${github_actions_output}"
publish_exclusively "${terraform_admin_temporary}" "${terraform_admin_output}"
publish_exclusively "${github_actions_temporary}" "${github_actions_output}"
echo "Permissions boundaries written with mode 0600."
