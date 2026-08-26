#!/usr/bin/env bash

set -euo pipefail

case "${1:-}" in
  --before-removal | --after-removal)
    verification_phase="$1"
    ;;
  *)
    echo "Use --before-removal or --after-removal." >&2
    exit 1
    ;;
esac

if (($# != 1)); then
  echo "Use --before-removal or --after-removal." >&2
  exit 1
fi

for command_name in aws git jq mktemp terraform; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${command_name}" >&2
    exit 1
  fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
module_dir="${repository_root}/infra/bootstrap"
backend_file="${module_dir}/backend.tf"
private_dir="${repository_root}/.private/terraform-bootstrap"
resolved_temporary_policy="${private_dir}/temporary-bootstrap-policy.json"
aws_profile="${AWS_PROFILE:-opensearch-lab-admin}"
bootstrap_user_name="opensearch-lab-bootstrap"
human_role_name="opensearch-lab-terraform-admin"
github_role_name="opensearch-lab-github-actions"
human_inline_name="opensearch-lab-bootstrap-management"
github_inline_name="opensearch-lab-bootstrap-state"
user_inline_name="opensearch-lab-assume-terraform-admin"

if [[ ! -f "${backend_file}" ]] || ! grep -Eq 'backend[[:space:]]+"s3"' "${backend_file}"; then
  echo "The verified S3 backend must be initialised first." >&2
  exit 1
fi

if [[ "${verification_phase}" == "--before-removal" && ! -f "${resolved_temporary_policy}" ]]; then
  echo "The resolved private temporary policy is required before removal." >&2
  exit 1
fi

mkdir -p "${private_dir}"
chmod 700 "${private_dir}"
umask 077
verification_dir="$(mktemp -d "${private_dir}/access-verification.XXXXXX")"
trap 'rm -rf -- "${verification_dir}"' EXIT
aws_error_file="${verification_dir}/aws-error.txt"

fail() {
  echo "$1" >&2
  exit 1
}

aws_json() {
  local output_file="$1"
  shift

  if ! aws --profile "${aws_profile}" "$@" --output json >"${output_file}" 2>"${aws_error_file}"; then
    fail "AWS access allow-list verification could not complete."
  fi
}

caller_file="${verification_dir}/caller.json"
aws_json "${caller_file}" sts get-caller-identity
account_id="$(jq -er '.Account | select(test("^[0-9]{12}$"))' "${caller_file}")"
caller_arn="$(jq -er '.Arn | select(type == "string")' "${caller_file}")"
partition="${caller_arn#arn:}"
partition="${partition%%:*}"

if [[ ! "${partition}" =~ ^[a-z0-9-]+$ ]] ||
  [[ ! "${caller_arn}" =~ ^arn:${partition}:sts::${account_id}:assumed-role/${human_role_name}/[^/]+$ ]]; then
  fail "Verification must run through the Terraform administration role."
fi

expected_file="${verification_dir}/expected.json"
if ! terraform -chdir="${module_dir}" show -json 2>"${verification_dir}/terraform-error.txt" |
  jq -e '
    def resource($address):
      [.values.root_module.resources[] | select(.address == $address)]
      | if length == 1 then .[0].values else error("missing resource") end;

    {
      user_inline: (
        resource("aws_iam_user_policy.bootstrap_user_assume_role").policy | fromjson
      ),
      human_trust: (
        resource("aws_iam_role.terraform_admin").assume_role_policy | fromjson
      ),
      human_inline: (
        resource("aws_iam_role_policy.terraform_admin").policy | fromjson
      ),
      github_trust: (
        resource("aws_iam_role.github_actions").assume_role_policy | fromjson
      ),
      github_inline: (
        resource("aws_iam_role_policy.github_actions_state").policy | fromjson
      ),
      oidc_url: (
        resource("aws_iam_openid_connect_provider.github").url | sub("^https://"; "")
      ),
      oidc_audiences: resource("aws_iam_openid_connect_provider.github").client_id_list,
      oidc_provider_arn: resource("aws_iam_openid_connect_provider.github").arn
    }
  ' >"${expected_file}"; then
  fail "Terraform state does not contain the expected bootstrap resources."
fi

user_file="${verification_dir}/user.json"
access_keys_file="${verification_dir}/access-keys.json"
groups_file="${verification_dir}/groups.json"
attached_user_file="${verification_dir}/attached-user.json"
inline_user_names_file="${verification_dir}/inline-user-names.json"
inline_user_policy_file="${verification_dir}/inline-user-policy.json"

aws_json "${user_file}" iam get-user --user-name "${bootstrap_user_name}"
aws_json "${access_keys_file}" iam list-access-keys --user-name "${bootstrap_user_name}"
aws_json "${groups_file}" iam list-groups-for-user --user-name "${bootstrap_user_name}"
aws_json "${attached_user_file}" iam list-attached-user-policies --user-name "${bootstrap_user_name}"
aws_json "${inline_user_names_file}" iam list-user-policies --user-name "${bootstrap_user_name}"
aws_json "${inline_user_policy_file}" iam get-user-policy \
  --user-name "${bootstrap_user_name}" \
  --policy-name "${user_inline_name}"

jq -e '.User.PermissionsBoundary == null' "${user_file}" >/dev/null ||
  fail "The bootstrap user has an unexpected permissions boundary."
jq -e '.AccessKeyMetadata | length == 0' "${access_keys_file}" >/dev/null ||
  fail "The bootstrap user has an access key."
jq -e '.Groups | length == 0' "${groups_file}" >/dev/null ||
  fail "The bootstrap user has unexpected group membership."
jq -e --arg expected "${user_inline_name}" \
  '.PolicyNames | sort == [$expected]' "${inline_user_names_file}" >/dev/null ||
  fail "The bootstrap user inline-policy allow-list failed."
jq -e --slurpfile actual "${inline_user_policy_file}" \
  '.user_inline == $actual[0].PolicyDocument' "${expected_file}" >/dev/null ||
  fail "The bootstrap user assume-role policy differs from Terraform state."

login_policy_arn="arn:${partition}:iam::aws:policy/SignInLocalDevelopmentAccess"
temporary_policy_arn="arn:${partition}:iam::${account_id}:policy/opensearch-lab-temporary-bootstrap"

if [[ "${verification_phase}" == "--before-removal" ]]; then
  jq -e --arg login "${login_policy_arn}" --arg temporary "${temporary_policy_arn}" '
    ([.AttachedPolicies[].PolicyArn] | sort) == ([$login, $temporary] | sort)
  ' "${attached_user_file}" >/dev/null ||
    fail "The bootstrap user attached-policy allow-list failed before removal."
else
  jq -e --arg login "${login_policy_arn}" '
    [.AttachedPolicies[].PolicyArn] == [$login]
  ' "${attached_user_file}" >/dev/null ||
    fail "The bootstrap user attached-policy allow-list failed after removal."
fi

verify_role() {
  local role_name="$1"
  local inline_name="$2"
  local expected_trust_key="$3"
  local expected_inline_key="$4"
  local role_slug="$5"
  local role_file="${verification_dir}/${role_slug}-role.json"
  local attached_file="${verification_dir}/${role_slug}-attached.json"
  local inline_names_file="${verification_dir}/${role_slug}-inline-names.json"
  local inline_policy_file="${verification_dir}/${role_slug}-inline-policy.json"

  aws_json "${role_file}" iam get-role --role-name "${role_name}"
  aws_json "${attached_file}" iam list-attached-role-policies --role-name "${role_name}"
  aws_json "${inline_names_file}" iam list-role-policies --role-name "${role_name}"
  aws_json "${inline_policy_file}" iam get-role-policy \
    --role-name "${role_name}" \
    --policy-name "${inline_name}"

  jq -e '.Role.PermissionsBoundary == null' "${role_file}" >/dev/null ||
    fail "A bootstrap role has an unexpected permissions boundary."
  jq -e '.AttachedPolicies | length == 0' "${attached_file}" >/dev/null ||
    fail "A bootstrap role has an unexpected attached policy."
  jq -e --arg expected "${inline_name}" \
    '.PolicyNames | sort == [$expected]' "${inline_names_file}" >/dev/null ||
    fail "A bootstrap role inline-policy allow-list failed."
  jq -e --arg trust_key "${expected_trust_key}" --slurpfile actual "${role_file}" '
    .[$trust_key] == $actual[0].Role.AssumeRolePolicyDocument
  ' "${expected_file}" >/dev/null ||
    fail "A bootstrap role trust policy differs from Terraform state."
  jq -e --arg inline_key "${expected_inline_key}" --slurpfile actual "${inline_policy_file}" '
    .[$inline_key] == $actual[0].PolicyDocument
  ' "${expected_file}" >/dev/null ||
    fail "A bootstrap role inline policy differs from Terraform state."
}

verify_role \
  "${human_role_name}" \
  "${human_inline_name}" \
  human_trust \
  human_inline \
  human
verify_role \
  "${github_role_name}" \
  "${github_inline_name}" \
  github_trust \
  github_inline \
  github

oidc_provider_arn="$(jq -er '.oidc_provider_arn | select(type == "string")' "${expected_file}")"
if [[ ! "${oidc_provider_arn}" =~ ^arn:${partition}:iam::${account_id}:oidc-provider/token\.actions\.githubusercontent\.com$ ]]; then
  fail "Terraform state contains an unexpected OIDC provider."
fi

oidc_file="${verification_dir}/oidc.json"
aws_json "${oidc_file}" iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "${oidc_provider_arn}"
jq -e --slurpfile actual "${oidc_file}" '
  .oidc_url == $actual[0].Url
  and (.oidc_audiences | sort) == ($actual[0].ClientIDList | sort)
  and .oidc_audiences == ["sts.amazonaws.com"]
' "${expected_file}" >/dev/null ||
  fail "The GitHub OIDC provider URL or audience allow-list failed."

if [[ "${verification_phase}" == "--before-removal" ]]; then
  policy_file="${verification_dir}/temporary-policy.json"
  entities_file="${verification_dir}/temporary-policy-entities.json"
  policy_version_file="${verification_dir}/temporary-policy-version.json"

  aws_json "${policy_file}" iam get-policy --policy-arn "${temporary_policy_arn}"
  aws_json "${entities_file}" iam list-entities-for-policy --policy-arn "${temporary_policy_arn}"
  default_version_id="$(jq -er '.Policy.DefaultVersionId | select(test("^v[1-9][0-9]*$"))' "${policy_file}")"
  aws_json "${policy_version_file}" iam get-policy-version \
    --policy-arn "${temporary_policy_arn}" \
    --version-id "${default_version_id}"

  jq -e --arg user "${bootstrap_user_name}" '
    ([.PolicyUsers[].UserName] == [$user])
    and (.PolicyGroups | length == 0)
    and (.PolicyRoles | length == 0)
  ' "${entities_file}" >/dev/null ||
    fail "The temporary policy is attached to an unexpected identity."
  jq -e --slurpfile actual "${policy_version_file}" '
    . == $actual[0].PolicyVersion.Document
  ' "${resolved_temporary_policy}" >/dev/null ||
    fail "The attached temporary policy differs from the resolved private policy."
else
  if aws --profile "${aws_profile}" iam get-policy \
    --policy-arn "${temporary_policy_arn}" \
    --output json >"${verification_dir}/deleted-policy.json" 2>"${aws_error_file}"; then
    fail "The temporary policy still exists after removal."
  fi
  grep -Fq 'NoSuchEntity' "${aws_error_file}" ||
    fail "The temporary policy deletion could not be verified."
fi

echo "Bootstrap access allow-list verification passed."
