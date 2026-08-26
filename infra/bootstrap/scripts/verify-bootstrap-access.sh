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

for command_name in aws git grep jq mktemp terraform; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${command_name}" >&2
    exit 1
  fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
module_dir="${repository_root}/infra/bootstrap"
backend_file="${module_dir}/backend.tf"
backend_contract_script="${module_dir}/scripts/check-backend-contract.sh"
contract_digest_script="${module_dir}/scripts/policy-contract-digest.sh"
policy_dir="${module_dir}/policies"
temporary_policy_template="${policy_dir}/temporary-bootstrap-policy.template.json"
human_boundary_template="${policy_dir}/terraform-admin-boundary.template.json"
github_boundary_template="${policy_dir}/github-actions-boundary.template.json"
private_dir="${repository_root}/.private/terraform-bootstrap"
resolved_temporary_policy="${private_dir}/temporary-bootstrap-policy.json"
resolved_human_boundary="${private_dir}/terraform-admin-boundary.json"
resolved_github_boundary="${private_dir}/github-actions-boundary.json"
aws_profile="${AWS_PROFILE:-opensearch-lab-admin}"
bootstrap_user_name="opensearch-lab-bootstrap"
human_role_name="opensearch-lab-terraform-admin"
github_role_name="opensearch-lab-github-actions"
human_inline_name="opensearch-lab-bootstrap-management"
github_inline_name="opensearch-lab-bootstrap-state"
temporary_template_digest="856ce1b87222cbb03b66085339670195f756591d652b3a4a2a134a3121aa9b3a"
human_boundary_template_digest="ad115920994021f6d73f337c1744223458279a282f53ed9d6e516e85c65a040d"
github_boundary_template_digest="21a1c3d24734eceb43fa2b0dd69f0748a89e480b5e20fcb41dd04ffa72e6f8b7"

if [[ ! -x "${backend_contract_script}" || ! -x "${contract_digest_script}" ]]; then
  echo "A required bootstrap contract checker is unavailable." >&2
  exit 1
fi

if [[ "${verification_phase}" == "--before-removal" && ! -f "${resolved_temporary_policy}" ]]; then
  echo "The resolved private temporary policy is required before removal." >&2
  exit 1
fi

if [[ ! -f "${resolved_human_boundary}" || ! -f "${resolved_github_boundary}" ]]; then
  echo "The resolved private permissions boundaries are required for verification." >&2
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

has_reviewed_digest() {
  local policy_file="$1"
  local reviewed_digest="$2"
  local actual_digest

  actual_digest="$("${contract_digest_script}" "${policy_file}" 2>/dev/null)" || return 1
  [[ "${actual_digest}" == "${reviewed_digest}" ]]
}

policy_documents_match() {
  local expected_policy="$1"
  local actual_policy="$2"
  local expected_digest
  local actual_digest

  expected_digest="$("${contract_digest_script}" "${expected_policy}" 2>/dev/null)" || return 1
  actual_digest="$("${contract_digest_script}" "${actual_policy}" 2>/dev/null)" || return 1
  [[ "${expected_digest}" == "${actual_digest}" ]]
}

render_resolved_policy() {
  local template_file="$1"
  local output_file="$2"
  local expiry="${3:-}"

  jq -ce \
    --arg account_id "${account_id}" \
    --arg expiry "${expiry}" \
    --arg partition "${partition}" \
    --arg state_bucket_name "${state_bucket_name}" '
      if $expiry != "" then
        (.Statement[] | select(.Effect == "Allow") |
          .Condition.DateLessThan["aws:CurrentTime"]) = $expiry
      else
        .
      end
      | walk(
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

state_bucket_name="opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"
terraform_admin_role_arn="arn:${partition}:iam::${account_id}:role/${human_role_name}"

if ! has_reviewed_digest "${temporary_policy_template}" "${temporary_template_digest}" ||
  ! has_reviewed_digest "${human_boundary_template}" "${human_boundary_template_digest}" ||
  ! has_reviewed_digest "${github_boundary_template}" "${github_boundary_template_digest}"; then
  fail "A tracked bootstrap policy template differs from its reviewed contract."
fi

expected_human_boundary="${verification_dir}/expected-human-boundary.json"
expected_github_boundary="${verification_dir}/expected-github-boundary.json"
if ! render_resolved_policy "${human_boundary_template}" "${expected_human_boundary}" ||
  ! render_resolved_policy "${github_boundary_template}" "${expected_github_boundary}" ||
  ! policy_documents_match "${expected_human_boundary}" "${resolved_human_boundary}" ||
  ! policy_documents_match "${expected_github_boundary}" "${resolved_github_boundary}"; then
  fail "A resolved private permissions boundary is stale or differs from its tracked template."
fi

if [[ "${verification_phase}" == "--before-removal" ]]; then
  if ! temporary_expiry="$(jq -er '
    [.Statement[] | select(.Effect == "Allow") |
      .Condition.DateLessThan["aws:CurrentTime"]] as $expiries
    | select((.Statement | length) == 12)
    | select(($expiries | length) == 12)
    | select(($expiries | unique | length) == 1)
    | $expiries[0] as $expiry
    | select($expiry | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    | ($expiry | fromdateiso8601) as $expiry_epoch
    | now as $current_epoch
    | select($expiry_epoch > $current_epoch)
    | select(($expiry_epoch - $current_epoch) <= 14400)
    | $expiry
  ' "${resolved_temporary_policy}" 2>/dev/null)"; then
    fail "The resolved private temporary policy is stale, expired or differs from its tracked template."
  fi

  expected_temporary_policy="${verification_dir}/expected-temporary-policy.json"
  if ! render_resolved_policy \
    "${temporary_policy_template}" \
    "${expected_temporary_policy}" \
    "${temporary_expiry}" ||
    ! policy_documents_match "${expected_temporary_policy}" "${resolved_temporary_policy}"; then
    fail "The resolved private temporary policy is stale, expired or differs from its tracked template."
  fi
fi

TF_STATE_BUCKET_NAME="${state_bucket_name}" \
  TF_ADMIN_ROLE_ARN="${terraform_admin_role_arn}" \
  "${backend_contract_script}" s3-migration "${backend_file}" >/dev/null

expected_file="${verification_dir}/expected.json"
if ! terraform -chdir="${module_dir}" show -json 2>"${verification_dir}/terraform-error.txt" |
  jq -e '
    def resource($address):
      [.values.root_module.resources[] | select(.address == $address)]
      | if length == 1 then .[0].values else error("missing resource") end;

    {
      human_trust: (
        resource("aws_iam_role.terraform_admin").assume_role_policy | fromjson
      ),
      human_boundary_arn: resource("aws_iam_role.terraform_admin").permissions_boundary,
      human_inline: (
        resource("aws_iam_role_policy.terraform_admin").policy | fromjson
      ),
      github_trust: (
        resource("aws_iam_role.github_actions").assume_role_policy | fromjson
      ),
      github_boundary_arn: resource("aws_iam_role.github_actions").permissions_boundary,
      github_inline: (
        resource("aws_iam_role_policy.github_actions_state").policy | fromjson
      ),
      state_bucket_name: resource("aws_s3_bucket.state").bucket,
      state_bucket_policy: (
        resource("aws_s3_bucket_policy.state").policy | fromjson
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
mfa_devices_file="${verification_dir}/mfa-devices.json"
attached_user_file="${verification_dir}/attached-user.json"
inline_user_names_file="${verification_dir}/inline-user-names.json"

aws_json "${user_file}" iam get-user --user-name "${bootstrap_user_name}"
aws_json "${access_keys_file}" iam list-access-keys --user-name "${bootstrap_user_name}"
aws_json "${groups_file}" iam list-groups-for-user --user-name "${bootstrap_user_name}"
aws_json "${mfa_devices_file}" iam list-mfa-devices --user-name "${bootstrap_user_name}"
aws_json "${attached_user_file}" iam list-attached-user-policies --user-name "${bootstrap_user_name}"
aws_json "${inline_user_names_file}" iam list-user-policies --user-name "${bootstrap_user_name}"

jq -e '.User.PermissionsBoundary == null' "${user_file}" >/dev/null ||
  fail "The bootstrap user has an unexpected permissions boundary."
jq -e '.AccessKeyMetadata | length == 0' "${access_keys_file}" >/dev/null ||
  fail "The bootstrap user has an access key."
jq -e '.Groups | length == 0' "${groups_file}" >/dev/null ||
  fail "The bootstrap user has unexpected group membership."
jq -e --arg user "${bootstrap_user_name}" '
  (.MFADevices | length) > 0
  and all(.MFADevices[]; .UserName == $user)
' "${mfa_devices_file}" >/dev/null ||
  fail "The bootstrap user does not have a live MFA device."
jq -e '.PolicyNames | length == 0' "${inline_user_names_file}" >/dev/null ||
  fail "The bootstrap user inline-policy allow-list failed."

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
  local expected_boundary_key="$5"
  local role_slug="$6"
  local role_file="${verification_dir}/${role_slug}-role.json"
  local attached_file="${verification_dir}/${role_slug}-attached.json"
  local inline_names_file="${verification_dir}/${role_slug}-inline-names.json"
  local inline_policy_file="${verification_dir}/${role_slug}-inline-policy.json"
  local expected_trust_file="${verification_dir}/${role_slug}-expected-trust.json"
  local actual_trust_file="${verification_dir}/${role_slug}-actual-trust.json"
  local expected_inline_file="${verification_dir}/${role_slug}-expected-inline.json"
  local actual_inline_file="${verification_dir}/${role_slug}-actual-inline.json"

  aws_json "${role_file}" iam get-role --role-name "${role_name}"
  aws_json "${attached_file}" iam list-attached-role-policies --role-name "${role_name}"
  aws_json "${inline_names_file}" iam list-role-policies --role-name "${role_name}"
  aws_json "${inline_policy_file}" iam get-role-policy \
    --role-name "${role_name}" \
    --policy-name "${inline_name}"

  jq -e --arg boundary_key "${expected_boundary_key}" --slurpfile actual "${role_file}" '
    .[$boundary_key] == $actual[0].Role.PermissionsBoundary.PermissionsBoundaryArn
  ' "${expected_file}" >/dev/null ||
    fail "A bootstrap role permissions boundary differs from Terraform state."
  jq -e '.AttachedPolicies | length == 0' "${attached_file}" >/dev/null ||
    fail "A bootstrap role has an unexpected attached policy."
  jq -e --arg expected "${inline_name}" \
    '.PolicyNames | sort == [$expected]' "${inline_names_file}" >/dev/null ||
    fail "A bootstrap role inline-policy allow-list failed."
  if ! jq -ce --arg trust_key "${expected_trust_key}" \
    '.[$trust_key]' "${expected_file}" >"${expected_trust_file}" ||
    ! jq -ce '.Role.AssumeRolePolicyDocument' \
      "${role_file}" >"${actual_trust_file}" ||
    ! policy_documents_match "${expected_trust_file}" "${actual_trust_file}"; then
    fail "A bootstrap role trust policy differs from Terraform state."
  fi
  if ! jq -ce --arg inline_key "${expected_inline_key}" \
    '.[$inline_key]' "${expected_file}" >"${expected_inline_file}" ||
    ! jq -ce '.PolicyDocument' "${inline_policy_file}" >"${actual_inline_file}" ||
    ! policy_documents_match "${expected_inline_file}" "${actual_inline_file}"; then
    fail "A bootstrap role inline policy differs from Terraform state."
  fi
}

verify_role \
  "${human_role_name}" \
  "${human_inline_name}" \
  human_trust \
  human_inline \
  human_boundary_arn \
  human
verify_role \
  "${github_role_name}" \
  "${github_inline_name}" \
  github_trust \
  github_inline \
  github_boundary_arn \
  github

verify_boundary() {
  local boundary_key="$1"
  local expected_name="$2"
  local resolved_document="$3"
  local boundary_slug="$4"
  local boundary_arn
  local default_version_id
  local policy_file="${verification_dir}/${boundary_slug}-boundary-policy.json"
  local version_file="${verification_dir}/${boundary_slug}-boundary-version.json"
  local live_document="${verification_dir}/${boundary_slug}-live-boundary.json"

  boundary_arn="$(jq -er --arg key "${boundary_key}" '.[$key]' "${expected_file}")"
  if [[ "${boundary_arn}" != "arn:${partition}:iam::${account_id}:policy/${expected_name}" ]]; then
    fail "Terraform state contains an unexpected permissions boundary."
  fi

  aws_json "${policy_file}" iam get-policy --policy-arn "${boundary_arn}"
  default_version_id="$(jq -er '.Policy.DefaultVersionId | select(test("^v[1-9][0-9]*$"))' "${policy_file}")"
  aws_json "${version_file}" iam get-policy-version \
    --policy-arn "${boundary_arn}" \
    --version-id "${default_version_id}"

  if ! jq -ce '.PolicyVersion.Document' "${version_file}" >"${live_document}" ||
    ! policy_documents_match "${resolved_document}" "${live_document}"; then
    fail "A live permissions boundary differs from its resolved private document."
  fi
}

verify_boundary \
  human_boundary_arn \
  opensearch-lab-terraform-admin-boundary \
  "${resolved_human_boundary}" \
  human
verify_boundary \
  github_boundary_arn \
  opensearch-lab-github-actions-boundary \
  "${resolved_github_boundary}" \
  github

expected_state_bucket_name="$(jq -er '.state_bucket_name | select(type == "string")' \
  "${expected_file}")"
if [[ "${expected_state_bucket_name}" != "${state_bucket_name}" ]]; then
  fail "Terraform state contains an unexpected state bucket."
fi

bucket_policy_file="${verification_dir}/state-bucket-policy.json"
expected_bucket_policy_file="${verification_dir}/expected-state-bucket-policy.json"
live_bucket_policy_file="${verification_dir}/live-state-bucket-policy.json"
aws_json "${bucket_policy_file}" s3api get-bucket-policy \
  --bucket "${state_bucket_name}"
if ! jq -ce '.state_bucket_policy' \
  "${expected_file}" >"${expected_bucket_policy_file}" ||
  ! jq -ce '.Policy | fromjson' \
    "${bucket_policy_file}" >"${live_bucket_policy_file}" ||
  ! policy_documents_match "${expected_bucket_policy_file}" "${live_bucket_policy_file}"; then
  fail "The live state bucket policy differs from Terraform state."
fi

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
  live_temporary_policy="${verification_dir}/live-temporary-policy.json"

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
  if ! jq -ce '.PolicyVersion.Document' \
    "${policy_version_file}" >"${live_temporary_policy}" ||
    ! policy_documents_match "${resolved_temporary_policy}" "${live_temporary_policy}"; then
    fail "The attached temporary policy differs from the resolved private policy."
  fi
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
