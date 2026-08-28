#!/usr/bin/env bash
set -euo pipefail

if (($# != 3)); then
  echo "Usage: $0 <aws-account-id> <state-bucket-name> <output>" >&2
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
output_file="$3"

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

validate_destination "${output_file}"

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
template_file="${script_directory}/../policies/temporary-bootstrap-policy.template.json"
if [[ ! -r "${template_file}" || ! -f "${template_file}" ]]; then
  echo "Policy template is unavailable: ${template_file}" >&2
  exit 1
fi

maximum_lifetime_seconds=$((4 * 60 * 60))
lifetime_seconds=14400
if ((lifetime_seconds <= 0 || lifetime_seconds > maximum_lifetime_seconds)); then
  echo "Temporary policy lifetime must not exceed four hours." >&2
  exit 1
fi
issued_at_epoch="$(jq -nr 'now | floor')"
expiry_epoch=$((issued_at_epoch + lifetime_seconds))
expiry="$(jq -nr --argjson value "${expiry_epoch}" '$value | todateiso8601')"

umask 077
temporary_file=""
cleanup() {
  local exit_status="$?"

  trap - EXIT HUP INT TERM
  [[ -z "${temporary_file}" ]] || rm -f -- "${temporary_file}"
  exit "${exit_status}"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

temporary_file="$(mktemp "${output_file}.tmp.XXXXXX")"
jq -ce \
  --arg account_id "${account_id}" \
  --arg bucket "${state_bucket_name}" \
  --arg expiry "${expiry}" '
    walk(
      if type == "string" then
        gsub("__AWS_ACCOUNT_ID__"; $account_id)
        | gsub("__STATE_BUCKET_NAME__"; $bucket)
        | gsub("__TEMPORARY_POLICY_EXPIRY_UTC__"; $expiry)
      else . end
    )
  ' "${template_file}" >"${temporary_file}"

if grep -Eq '__[A-Z0-9_]+__' "${temporary_file}"; then
  echo "Resolved policy still contains a template placeholder." >&2
  exit 1
fi
if ! jq -e 'type == "object"' "${temporary_file}" >/dev/null; then
  echo "Resolved policy is not valid JSON." >&2
  exit 1
fi

if ! jq -e \
  --arg account_id "${account_id}" \
  --arg bucket "${state_bucket_name}" \
  --arg expiry "${expiry}" \
  --argjson issued_at_epoch "${issued_at_epoch}" \
  --argjson maximum_lifetime_seconds "${maximum_lifetime_seconds}" '
    def list: if type == "array" then . else [.] end;
    def actions: [.Statement[] | .Action | list[]];
    def resources: [.Statement[] | .Resource | list[]];
    [
      "billing:GetBillingViewData",
      "budgets:ListTagsForResource", "budgets:ModifyBudget",
      "budgets:TagResource", "budgets:UntagResource", "budgets:ViewBudget",
      "iam:CreateOpenIDConnectProvider", "iam:CreateRole",
      "iam:GetOpenIDConnectProvider", "iam:GetRole", "iam:GetRolePolicy", "iam:GetUser",
      "iam:ListAttachedRolePolicies", "iam:ListOpenIDConnectProviderTags",
      "iam:ListRolePolicies", "iam:ListRoleTags", "iam:PutRolePolicy",
      "iam:TagOpenIDConnectProvider", "iam:TagRole",
      "s3:CreateBucket", "s3:DeleteObject", "s3:GetAccelerateConfiguration",
      "s3:GetBucketAcl", "s3:GetBucketCORS", "s3:GetBucketLocation",
      "s3:GetBucketLogging", "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketOwnershipControls", "s3:GetBucketPolicy",
      "s3:GetBucketPublicAccessBlock", "s3:GetBucketRequestPayment",
      "s3:GetBucketVersioning", "s3:GetBucketWebsite", "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration", "s3:GetObject", "s3:GetReplicationConfiguration",
      "s3:ListBucket", "s3:ListTagsForResource", "s3:PutBucketOwnershipControls",
      "s3:PutBucketPolicy", "s3:PutBucketPublicAccessBlock", "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration", "s3:PutLifecycleConfiguration", "s3:PutObject",
      "s3:TagResource", "s3:UntagResource"
    ] as $allowed_actions
    | . as $policy
    | ($policy | actions) as $actions
    | ($policy | resources) as $resources
    | ("arn:aws:s3:::" + $bucket) as $bucket_arn
    | ("arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap") as $principal
    | ("arn:aws:signin:*:" + $account_id + ":session/*") as $session
    | [
        "arn:aws:iam::" + $account_id + ":policy/opensearch-lab-terraform-admin-boundary",
        "arn:aws:iam::" + $account_id + ":policy/opensearch-lab-github-actions-boundary"
      ] as $boundaries
    | $policy.Version == "2012-10-17"
      and ($policy.Statement | type == "array" and length > 0)
      and all($policy.Statement[]; .Effect == "Allow")
      and all($policy.Statement[]; has("Action") and has("Resource") and has("Condition"))
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
        (.Condition | keys | sort) == ["ArnEquals", "ArnLike", "DateLessThan"]
        and .Condition.ArnEquals["aws:PrincipalArn"] == $principal
        and .Condition.ArnLike == {"aws:SignInSessionArn": $session}
        and .Condition.DateLessThan == {"aws:CurrentTime": $expiry}
      )
      and all(
        $policy.Statement[];
        (.Action | list) as $statement_actions
        | if (($statement_actions | index("iam:CreateRole")) != null
          or ($statement_actions | index("iam:PutRolePolicy")) != null) then
            (.Condition.ArnEquals | keys | sort)
              == ["aws:PrincipalArn", "iam:PermissionsBoundary"]
            and (.Condition.ArnEquals["iam:PermissionsBoundary"] as $boundary
              | ($boundaries | index($boundary)) != null)
          else
            (.Condition.ArnEquals | keys) == ["aws:PrincipalArn"]
          end
      )
      and ([.Statement[].Condition.DateLessThan["aws:CurrentTime"]] | unique) == [$expiry]
      and (($expiry | fromdateiso8601) > $issued_at_epoch)
      and (($expiry | fromdateiso8601) - $issued_at_epoch <= $maximum_lifetime_seconds)
      and ($actions | index("iam:AttachUserPolicy")) == null
      and ($actions | index("iam:PutUserPermissionsBoundary")) == null
      and ($actions | index("iam:PutRolePermissionsBoundary")) == null
  ' "${temporary_file}" >/dev/null; then
  echo "Temporary policy failed its security contract." >&2
  exit 1
fi

if (($(wc -c <"${temporary_file}") > 6144)); then
  echo "Resolved policy exceeds the IAM managed-policy size limit." >&2
  exit 1
fi

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

chmod 0600 "${temporary_file}"
if [[ "$(file_mode "${temporary_file}")" != "600" ]]; then
  echo "Resolved policy does not have mode 0600." >&2
  exit 1
fi

validate_destination "${output_file}"
publish_exclusively "${temporary_file}" "${output_file}"
echo "Temporary policy written with mode 0600 and a four-hour UTC expiry."
