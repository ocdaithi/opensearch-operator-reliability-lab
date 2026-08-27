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

for command_name in aws git grep jq mktemp sleep terraform; do
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
budget_name="opensearch-lab-monthly-cost"
github_subject="repo:ocdaithi@321047870/opensearch-operator-reliability-lab@1346323330:environment:aws-bootstrap"
temporary_template_digest="8bde0769132eb0bb831c83a5c02a6773e585d989af56d174a28dc7a707a61a1a"
human_boundary_template_digest="c8592acc57fea897687b8b9b12cba677d9411f47b5c92280c3576f57846ff906"
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
iam_retry_attempts=5
iam_retry_delay_seconds="${BOOTSTRAP_VERIFY_IAM_RETRY_DELAY_SECONDS:-2}"

fail() {
  echo "$1" >&2
  exit 1
}

if [[ ! "${iam_retry_delay_seconds}" =~ ^[0-2]$ ]]; then
  fail "The IAM retry delay must be between zero and two seconds."
fi

budget_notification_email="${BUDGET_NOTIFICATION_EMAIL:-}"
if ((${#budget_notification_email} > 254)) ||
  [[ ! "${budget_notification_email}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
  fail "BUDGET_NOTIFICATION_EMAIL must contain the exact reviewed budget recipient."
fi

has_reviewed_digest() {
  local policy_file="$1"
  local reviewed_digest="$2"
  local actual_digest

  actual_digest="$("${contract_digest_script}" "${policy_file}" 2>/dev/null)" || return 1
  [[ "${actual_digest}" == "${reviewed_digest}" ]]
}

has_reviewed_static_policy_contracts() {
  jq -e '
    def statement($sid):
      [.Statement[] | select(.Sid == $sid)]
      | if length == 1 then .[0] else null end;
    . as $policy
    | [.Statement[] | select(.Effect == "Allow")] as $allows
    | ($policy.Statement | length) == 11
      and ($allows | length) == 11
      and all($policy.Statement[]; .Sid != "ListExactTerraformStateKeys")
      and all($allows[];
        .Condition.ArnEquals["aws:PrincipalArn"]
          == "arn:aws:iam::__AWS_ACCOUNT_ID__:user/opensearch-lab-bootstrap"
        and .Condition.ArnLike["aws:SignInSessionArn"]
          == "arn:aws:signin:*:__AWS_ACCOUNT_ID__:session/*"
        and .Condition.DateLessThan["aws:CurrentTime"]
          == "__TEMPORARY_POLICY_EXPIRY_UTC__"
      )
      and ($policy | statement("ReadDefaultBillingViewData") |
        .Action == "billing:GetBillingViewData"
        and .Resource
          == "arn:aws:billing::__AWS_ACCOUNT_ID__:billingview/primary")
  ' "${temporary_policy_template}" >/dev/null &&
    jq -e '
      def statement($sid):
        [.Statement[] | select(.Sid == $sid)]
        | if length == 1 then .[0] else null end;
      . as $policy
      | ($policy.Statement | length) == 11
        and all($policy.Statement[]; .Sid != "ListExactTerraformStateKeys")
        and ($policy | statement("ReadDefaultBillingViewData") |
          .Action == "billing:GetBillingViewData"
          and .Resource == (
            "arn:__AWS_PARTITION__:billing::__AWS_ACCOUNT_ID__:"
            + "billingview/primary"
          ))
    ' "${human_boundary_template}" >/dev/null
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

aws_iam_json() {
  local output_file="$1"
  local attempt
  shift

  for ((attempt = 1; attempt <= iam_retry_attempts; attempt++)); do
    if aws --profile "${aws_profile}" "$@" --output json >"${output_file}" 2>"${aws_error_file}"; then
      return 0
    fi

    if ((attempt == iam_retry_attempts)) ||
      ! grep -Fq 'An error occurred (NoSuchEntity)' "${aws_error_file}"; then
      fail "AWS access allow-list verification could not complete."
    fi

    sleep "${iam_retry_delay_seconds}"
  done
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

if ! has_reviewed_static_policy_contracts ||
  ! has_reviewed_digest "${temporary_policy_template}" "${temporary_template_digest}" ||
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
  if ! temporary_expiry="$(jq -er \
    --arg billing_view_arn "arn:aws:billing::${account_id}:billingview/primary" \
    --arg principal_arn "arn:aws:iam::${account_id}:user/${bootstrap_user_name}" \
    --arg sign_in_session_arn "arn:aws:signin:*:${account_id}:session/*" '
    . as $policy
    | [.Statement[] | select(.Effect == "Allow")] as $allows
    | [$allows[] | select(.Sid == "ReadDefaultBillingViewData")] as $billing_statements
    | [$allows[].Condition.DateLessThan["aws:CurrentTime"]] as $expiries
    | select(($policy.Statement | length) == 11)
    | select(($allows | length) == 11)
    | select(($expiries | length) == 11)
    | select(($expiries | unique | length) == 1)
    | select(all($allows[];
        .Condition.ArnEquals["aws:PrincipalArn"] == $principal_arn
        and .Condition.ArnLike["aws:SignInSessionArn"]
          == $sign_in_session_arn
      ))
    | select(($billing_statements | length) == 1)
    | select($billing_statements[0].Action == "billing:GetBillingViewData")
    | select($billing_statements[0].Resource == $billing_view_arn)
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

expected_human_trust="${verification_dir}/expected-human-trust.json"
expected_github_trust="${verification_dir}/expected-github-trust.json"
expected_bucket_policy="${verification_dir}/expected-state-bucket-policy.json"
expected_human_boundary_arn="arn:${partition}:iam::${account_id}:policy/opensearch-lab-terraform-admin-boundary"
expected_github_boundary_arn="arn:${partition}:iam::${account_id}:policy/opensearch-lab-github-actions-boundary"
oidc_provider_arn="arn:${partition}:iam::${account_id}:oidc-provider/token.actions.githubusercontent.com"

jq -nc \
  --arg account_id "${account_id}" \
  --arg partition "${partition}" '{
    Version: "2012-10-17",
    Statement: [{
      Sid: "AllowExactBootstrapUser",
      Effect: "Allow",
      Action: "sts:AssumeRole",
      Principal: {
        AWS: ("arn:" + $partition + ":iam::" + $account_id + ":user/opensearch-lab-bootstrap")
      },
      Condition: {
        ArnLike: {
          "aws:SignInSessionArn": (
            "arn:" + $partition + ":signin:*:" + $account_id + ":session/*"
          )
        }
      }
    }]
  }' >"${expected_human_trust}"

jq -nc \
  --arg github_subject "${github_subject}" \
  --arg oidc_provider_arn "${oidc_provider_arn}" '{
    Version: "2012-10-17",
    Statement: [{
      Sid: "AllowExactRepositoryEnvironment",
      Effect: "Allow",
      Action: "sts:AssumeRoleWithWebIdentity",
      Principal: {Federated: $oidc_provider_arn},
      Condition: {
        StringEquals: {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": $github_subject
        }
      }
    }]
  }' >"${expected_github_trust}"

jq -nc --arg bucket "${state_bucket_name}" --arg partition "${partition}" '{
  Version: "2012-10-17",
  Statement: [{
    Sid: "DenyInsecureTransport",
    Effect: "Deny",
    Action: "s3:*",
    Principal: "*",
    Resource: [
      ("arn:" + $partition + ":s3:::" + $bucket),
      ("arn:" + $partition + ":s3:::" + $bucket + "/*")
    ],
    Condition: {Bool: {"aws:SecureTransport": "false"}}
  }]
}' >"${expected_bucket_policy}"

terraform_state_file="${verification_dir}/terraform-state.json"
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
      human_max_session_duration: resource("aws_iam_role.terraform_admin").max_session_duration,
      human_inline: (
        resource("aws_iam_role_policy.terraform_admin").policy | fromjson
      ),
      github_trust: (
        resource("aws_iam_role.github_actions").assume_role_policy | fromjson
      ),
      github_boundary_arn: resource("aws_iam_role.github_actions").permissions_boundary,
      github_max_session_duration: resource("aws_iam_role.github_actions").max_session_duration,
      github_inline: (
        resource("aws_iam_role_policy.github_actions_state").policy | fromjson
      ),
      state_bucket_name: resource("aws_s3_bucket.state").bucket,
      state_versioning: resource("aws_s3_bucket_versioning.state").versioning_configuration,
      state_encryption: resource("aws_s3_bucket_server_side_encryption_configuration.state").rule,
      state_public_access_block: resource("aws_s3_bucket_public_access_block.state"),
      state_ownership: resource("aws_s3_bucket_ownership_controls.state").rule,
      state_lifecycle: resource("aws_s3_bucket_lifecycle_configuration.state").rule,
      state_bucket_policy: (
        resource("aws_s3_bucket_policy.state").policy | fromjson
      ),
      oidc_url: (
        resource("aws_iam_openid_connect_provider.github").url | sub("^https://"; "")
      ),
      oidc_audiences: resource("aws_iam_openid_connect_provider.github").client_id_list,
      oidc_provider_arn: resource("aws_iam_openid_connect_provider.github").arn,
      budget: resource("aws_budgets_budget.account_cost")
    }
  ' >"${terraform_state_file}"; then
  fail "Terraform state does not contain the expected bootstrap resources."
fi

state_human_trust="${verification_dir}/state-human-trust.json"
state_github_trust="${verification_dir}/state-github-trust.json"
state_human_inline="${verification_dir}/state-human-inline.json"
state_github_inline="${verification_dir}/state-github-inline.json"
state_bucket_policy="${verification_dir}/state-bucket-policy-contract.json"

# Each inline policy intentionally has the same reviewed semantics as its role boundary.
if ! jq -ce '.human_trust' "${terraform_state_file}" >"${state_human_trust}" ||
  ! policy_documents_match "${expected_human_trust}" "${state_human_trust}" ||
  ! jq -ce '.github_trust' "${terraform_state_file}" >"${state_github_trust}" ||
  ! policy_documents_match "${expected_github_trust}" "${state_github_trust}" ||
  ! jq -ce '.human_inline' "${terraform_state_file}" >"${state_human_inline}" ||
  ! policy_documents_match "${expected_human_boundary}" "${state_human_inline}" ||
  ! jq -ce '.github_inline' "${terraform_state_file}" >"${state_github_inline}" ||
  ! policy_documents_match "${expected_github_boundary}" "${state_github_inline}" ||
  ! jq -ce '.state_bucket_policy' "${terraform_state_file}" >"${state_bucket_policy}" ||
  ! policy_documents_match "${expected_bucket_policy}" "${state_bucket_policy}"; then
  fail "Terraform state policy semantics differ from the independent reviewed contract."
fi

if ! jq -e \
  --arg account_id "${account_id}" \
  --arg budget_arn "arn:${partition}:budgets::${account_id}:budget/${budget_name}" \
  --arg bucket "${state_bucket_name}" \
  --arg budget_notification_email "${budget_notification_email}" \
  --arg github_boundary "${expected_github_boundary_arn}" \
  --arg human_boundary "${expected_human_boundary_arn}" \
  --arg oidc_arn "${oidc_provider_arn}" '
    .human_boundary_arn == $human_boundary
    and .github_boundary_arn == $github_boundary
    and .human_max_session_duration == 3600
    and .github_max_session_duration == 3600
    and .state_bucket_name == $bucket
    and .oidc_url == "token.actions.githubusercontent.com"
    and .oidc_audiences == ["sts.amazonaws.com"]
    and .oidc_provider_arn == $oidc_arn
    and (.state_versioning | length) == 1
    and .state_versioning[0].status == "Enabled"
    and ((.state_versioning[0].mfa_delete // "") | IN("", "Disabled"))
    and (.state_encryption | length) == 1
    and (.state_encryption[0].apply_server_side_encryption_by_default | length) == 1
    and .state_encryption[0].apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    and ((.state_encryption[0].apply_server_side_encryption_by_default[0].kms_master_key_id // "") == "")
    and ((.state_encryption[0].bucket_key_enabled // false) == false)
    and .state_public_access_block.block_public_acls == true
    and .state_public_access_block.block_public_policy == true
    and .state_public_access_block.ignore_public_acls == true
    and .state_public_access_block.restrict_public_buckets == true
    and (.state_ownership | length) == 1
    and .state_ownership[0].object_ownership == "BucketOwnerEnforced"
    and (.state_lifecycle | length) == 1
    and .state_lifecycle[0].id == "retain-recent-noncurrent-state"
    and .state_lifecycle[0].status == "Enabled"
    and (.state_lifecycle[0].filter | length) == 1
    and .state_lifecycle[0].filter[0].prefix == ""
    and ((.state_lifecycle[0].filter[0].and // []) | length) == 0
    and ((.state_lifecycle[0].filter[0].tag // []) | length) == 0
    and .state_lifecycle[0].filter[0].object_size_greater_than == null
    and .state_lifecycle[0].filter[0].object_size_less_than == null
    and ((.state_lifecycle[0].filter[0] | keys) - [
      "and",
      "object_size_greater_than",
      "object_size_less_than",
      "prefix",
      "tag"
    ] | length) == 0
    and ((.state_lifecycle[0].abort_incomplete_multipart_upload // []) | length) == 0
    and .state_lifecycle[0].prefix == null
    and (.state_lifecycle[0].noncurrent_version_expiration | length) == 1
    and .state_lifecycle[0].noncurrent_version_expiration[0].newer_noncurrent_versions == 10
    and .state_lifecycle[0].noncurrent_version_expiration[0].noncurrent_days == 90
    and ((.state_lifecycle[0].expiration // []) | length) == 0
    and ((.state_lifecycle[0].transition // []) | length) == 0
    and ((.state_lifecycle[0].noncurrent_version_transition // []) | length) == 0
    and ((.state_lifecycle[0] | keys) - [
      "abort_incomplete_multipart_upload",
      "expiration",
      "filter",
      "id",
      "noncurrent_version_expiration",
      "noncurrent_version_transition",
      "prefix",
      "status",
      "transition"
    ] | length) == 0
    and .budget.name == "opensearch-lab-monthly-cost"
    and .budget.arn == $budget_arn
    and .budget.account_id == $account_id
    and .budget.budget_type == "COST"
    and (.budget.limit_amount | tonumber) == 50
    and .budget.limit_unit == "USD"
    and .budget.time_unit == "MONTHLY"
    and (.budget.metrics | sort) == ["UnblendedCost"]
    and .budget.billing_view_arn == null
    and ((.budget.auto_adjust_data // []) | length) == 0
    and ((.budget.planned_limit // []) | length) == 0
    and ((.budget.cost_filter // []) | length) == 0
    and ((.budget.cost_types // []) | length) == 0
    and (.budget.filter_expression | length) == 1
    and ((.budget.filter_expression[0].and // []) | length) == 0
    and ((.budget.filter_expression[0].or // []) | length) == 0
    and ((.budget.filter_expression[0].dimensions // []) | length) == 0
    and ((.budget.filter_expression[0].tags // []) | length) == 0
    and ((.budget.filter_expression[0].cost_categories // []) | length) == 0
    and (.budget.filter_expression[0].not | length) == 1
    and ((.budget.filter_expression[0].not[0].and // []) | length) == 0
    and ((.budget.filter_expression[0].not[0].or // []) | length) == 0
    and ((.budget.filter_expression[0].not[0].not // []) | length) == 0
    and ((.budget.filter_expression[0].not[0].tags // []) | length) == 0
    and ((.budget.filter_expression[0].not[0].cost_categories // []) | length) == 0
    and (.budget.filter_expression[0].not[0].dimensions | length) == 1
    and .budget.filter_expression[0].not[0].dimensions[0].key == "RECORD_TYPE"
    and (.budget.filter_expression[0].not[0].dimensions[0].values | sort) == ["Credit", "Refund"]
    and (
      (.budget.filter_expression[0].not[0].dimensions[0].match_options // [])
      | length == 0 or sort == ["EQUALS"]
    )
    and (.budget.notification | length) == 5
    and ([.budget.notification[] | select(.notification_type == "ACTUAL") | .threshold] | sort) == [10, 25, 40, 50]
    and ([.budget.notification[] | select(.notification_type == "FORECASTED") | .threshold]) == [50]
    and all(.budget.notification[];
      .comparison_operator == "GREATER_THAN"
      and .threshold_type == "ABSOLUTE_VALUE"
      and .subscriber_email_addresses == [$budget_notification_email]
      and ((.subscriber_sns_topic_arns // []) | length) == 0
    )
  ' "${terraform_state_file}" >/dev/null; then
  fail "Terraform state resource settings differ from the independent reviewed contract."
fi

user_file="${verification_dir}/user.json"
access_keys_file="${verification_dir}/access-keys.json"
groups_file="${verification_dir}/groups.json"
mfa_devices_file="${verification_dir}/mfa-devices.json"
attached_user_file="${verification_dir}/attached-user.json"
inline_user_names_file="${verification_dir}/inline-user-names.json"

aws_iam_json "${user_file}" iam get-user --user-name "${bootstrap_user_name}"
aws_iam_json "${access_keys_file}" iam list-access-keys --user-name "${bootstrap_user_name}"
aws_iam_json "${groups_file}" iam list-groups-for-user --user-name "${bootstrap_user_name}"
aws_iam_json "${mfa_devices_file}" iam list-mfa-devices --user-name "${bootstrap_user_name}"
aws_iam_json "${attached_user_file}" iam list-attached-user-policies --user-name "${bootstrap_user_name}"
aws_iam_json "${inline_user_names_file}" iam list-user-policies --user-name "${bootstrap_user_name}"

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
  local expected_trust_file="$3"
  local expected_inline_file="$4"
  local expected_boundary_arn="$5"
  local role_slug="$6"
  local role_file="${verification_dir}/${role_slug}-role.json"
  local attached_file="${verification_dir}/${role_slug}-attached.json"
  local inline_names_file="${verification_dir}/${role_slug}-inline-names.json"
  local inline_policy_file="${verification_dir}/${role_slug}-inline-policy.json"
  local actual_trust_file="${verification_dir}/${role_slug}-actual-trust.json"
  local actual_inline_file="${verification_dir}/${role_slug}-actual-inline.json"

  aws_iam_json "${role_file}" iam get-role --role-name "${role_name}"
  aws_iam_json "${attached_file}" iam list-attached-role-policies --role-name "${role_name}"
  aws_iam_json "${inline_names_file}" iam list-role-policies --role-name "${role_name}"
  aws_iam_json "${inline_policy_file}" iam get-role-policy \
    --role-name "${role_name}" \
    --policy-name "${inline_name}"

  jq -e --arg boundary "${expected_boundary_arn}" '
    .Role.PermissionsBoundary.PermissionsBoundaryArn == $boundary
    and .Role.MaxSessionDuration == 3600
  ' "${role_file}" >/dev/null ||
    fail "A bootstrap role boundary or maximum session duration differs from the reviewed contract."
  jq -e '.AttachedPolicies | length == 0' "${attached_file}" >/dev/null ||
    fail "A bootstrap role has an unexpected attached policy."
  jq -e --arg expected "${inline_name}" \
    '.PolicyNames | sort == [$expected]' "${inline_names_file}" >/dev/null ||
    fail "A bootstrap role inline-policy allow-list failed."
  if ! jq -ce '.Role.AssumeRolePolicyDocument' \
      "${role_file}" >"${actual_trust_file}" ||
    ! policy_documents_match "${expected_trust_file}" "${actual_trust_file}"; then
    fail "A bootstrap role trust policy differs from the independent reviewed contract."
  fi
  if ! jq -ce '.PolicyDocument' "${inline_policy_file}" >"${actual_inline_file}" ||
    ! policy_documents_match "${expected_inline_file}" "${actual_inline_file}"; then
    fail "A bootstrap role inline policy differs from the independent reviewed contract."
  fi
}

verify_role \
  "${human_role_name}" \
  "${human_inline_name}" \
  "${expected_human_trust}" \
  "${expected_human_boundary}" \
  "${expected_human_boundary_arn}" \
  human
verify_role \
  "${github_role_name}" \
  "${github_inline_name}" \
  "${expected_github_trust}" \
  "${expected_github_boundary}" \
  "${expected_github_boundary_arn}" \
  github

verify_boundary() {
  local boundary_arn="$1"
  local expected_document="$2"
  local boundary_slug="$3"
  local default_version_id
  local policy_file="${verification_dir}/${boundary_slug}-boundary-policy.json"
  local version_file="${verification_dir}/${boundary_slug}-boundary-version.json"
  local live_document="${verification_dir}/${boundary_slug}-live-boundary.json"

  aws_iam_json "${policy_file}" iam get-policy --policy-arn "${boundary_arn}"
  default_version_id="$(jq -er '.Policy.DefaultVersionId | select(test("^v[1-9][0-9]*$"))' "${policy_file}")"
  aws_iam_json "${version_file}" iam get-policy-version \
    --policy-arn "${boundary_arn}" \
    --version-id "${default_version_id}"

  if ! jq -ce '.PolicyVersion.Document' "${version_file}" >"${live_document}" ||
    ! policy_documents_match "${expected_document}" "${live_document}"; then
    fail "A live permissions boundary differs from the independent reviewed contract."
  fi
}

verify_boundary \
  "${expected_human_boundary_arn}" \
  "${expected_human_boundary}" \
  human
verify_boundary \
  "${expected_github_boundary_arn}" \
  "${expected_github_boundary}" \
  github

bucket_policy_file="${verification_dir}/state-bucket-policy.json"
live_bucket_policy_file="${verification_dir}/live-state-bucket-policy.json"
aws_json "${bucket_policy_file}" s3api get-bucket-policy \
  --bucket "${state_bucket_name}"
if ! jq -ce '.Policy | fromjson' \
    "${bucket_policy_file}" >"${live_bucket_policy_file}" ||
  ! policy_documents_match "${expected_bucket_policy}" "${live_bucket_policy_file}"; then
  fail "The live state bucket policy differs from the independent reviewed contract."
fi

bucket_versioning_file="${verification_dir}/state-bucket-versioning.json"
bucket_encryption_file="${verification_dir}/state-bucket-encryption.json"
bucket_public_access_file="${verification_dir}/state-bucket-public-access.json"
bucket_ownership_file="${verification_dir}/state-bucket-ownership.json"
bucket_lifecycle_file="${verification_dir}/state-bucket-lifecycle.json"

aws_json "${bucket_versioning_file}" s3api get-bucket-versioning --bucket "${state_bucket_name}"
aws_json "${bucket_encryption_file}" s3api get-bucket-encryption --bucket "${state_bucket_name}"
aws_json "${bucket_public_access_file}" s3api get-public-access-block --bucket "${state_bucket_name}"
aws_json "${bucket_ownership_file}" s3api get-bucket-ownership-controls --bucket "${state_bucket_name}"
aws_json "${bucket_lifecycle_file}" s3api get-bucket-lifecycle-configuration --bucket "${state_bucket_name}"

jq -e '
  .Status == "Enabled"
  and ((.MFADelete // "Disabled") == "Disabled")
  and ((keys - ["MFADelete", "Status"]) | length) == 0
' "${bucket_versioning_file}" >/dev/null ||
  fail "The live state bucket versioning differs from the reviewed contract."

jq -e '
  (.ServerSideEncryptionConfiguration.Rules | length) == 1
  and .ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm == "AES256"
  and (.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID == null)
  and ((.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault | keys) == ["SSEAlgorithm"])
  and ((.ServerSideEncryptionConfiguration.Rules[0].BucketKeyEnabled // false) == false)
  and ((.ServerSideEncryptionConfiguration.Rules[0] | keys) - ["ApplyServerSideEncryptionByDefault", "BucketKeyEnabled"] | length) == 0
' "${bucket_encryption_file}" >/dev/null ||
  fail "The live state bucket encryption differs from the reviewed AES256 contract."

jq -e '
  .PublicAccessBlockConfiguration == {
    BlockPublicAcls: true,
    BlockPublicPolicy: true,
    IgnorePublicAcls: true,
    RestrictPublicBuckets: true
  }
' "${bucket_public_access_file}" >/dev/null ||
  fail "The live state bucket public-access block differs from the reviewed contract."

jq -e '
  .OwnershipControls.Rules == [{ObjectOwnership: "BucketOwnerEnforced"}]
' "${bucket_ownership_file}" >/dev/null ||
  fail "The live state bucket ownership controls differ from the reviewed contract."

jq -e '
  (.Rules | length) == 1
  and .Rules[0].ID == "retain-recent-noncurrent-state"
  and .Rules[0].Status == "Enabled"
  and .Rules[0].Filter == {Prefix: ""}
  and .Rules[0].NoncurrentVersionExpiration == {
    NoncurrentDays: 90,
    NewerNoncurrentVersions: 10
  }
  and (.Rules[0] | keys) == ["Filter", "ID", "NoncurrentVersionExpiration", "Status"]
' "${bucket_lifecycle_file}" >/dev/null ||
  fail "The live state bucket lifecycle configuration differs from the reviewed contract."

oidc_file="${verification_dir}/oidc.json"
aws_iam_json "${oidc_file}" iam get-open-id-connect-provider \
  --open-id-connect-provider-arn "${oidc_provider_arn}"
jq -e '
  .Url == "token.actions.githubusercontent.com"
  and .ClientIDList == ["sts.amazonaws.com"]
' "${oidc_file}" >/dev/null ||
  fail "The GitHub OIDC provider URL or audience allow-list failed."

budget_file="${verification_dir}/budget.json"
budget_notifications_file="${verification_dir}/budget-notifications.json"
expected_notifications_file="${verification_dir}/expected-budget-notifications.json"
live_notifications_file="${verification_dir}/live-budget-notifications.json"

aws_json "${budget_file}" budgets describe-budget \
  --account-id "${account_id}" \
  --budget-name "${budget_name}" \
  --show-filter-expression
aws_json "${budget_notifications_file}" budgets describe-notifications-for-budget \
  --account-id "${account_id}" \
  --budget-name "${budget_name}"

jq -e --arg budget_name "${budget_name}" '
  .Budget.BudgetName == $budget_name
  and (.Budget.BudgetLimit.Amount | tonumber) == 50
  and .Budget.BudgetLimit.Unit == "USD"
  and .Budget.BudgetType == "COST"
  and .Budget.TimeUnit == "MONTHLY"
  and (.Budget.Metrics | sort) == ["UnblendedCost"]
  and ((.Budget.CostFilters // {}) | length) == 0
  and .Budget.CostTypes == null
  and (.Budget.FilterExpression | keys) == ["Not"]
  and (.Budget.FilterExpression.Not | keys) == ["Dimensions"]
  and .Budget.FilterExpression.Not.Dimensions.Key == "RECORD_TYPE"
  and (.Budget.FilterExpression.Not.Dimensions.Values | sort) == ["Credit", "Refund"]
  and (
    (.Budget.FilterExpression.Not.Dimensions.MatchOptions // [])
    | length == 0 or sort == ["EQUALS"]
  )
  and ((.Budget.FilterExpression.Not.Dimensions | keys) - ["Key", "MatchOptions", "Values"] | length) == 0
  and .Budget.AutoAdjustData == null
  and .Budget.PlannedBudgetLimits == null
  and .Budget.BillingViewArn == null
' "${budget_file}" >/dev/null ||
  fail "The live budget identity, amount or filters differ from the reviewed contract."

jq -nc '[10, 25, 40, 50] as $actual_thresholds |
  ([ $actual_thresholds[] | {
    NotificationType: "ACTUAL",
    ComparisonOperator: "GREATER_THAN",
    Threshold: .,
    ThresholdType: "ABSOLUTE_VALUE"
  } ] + [{
    NotificationType: "FORECASTED",
    ComparisonOperator: "GREATER_THAN",
    Threshold: 50,
    ThresholdType: "ABSOLUTE_VALUE"
  }])
' >"${expected_notifications_file}"

if ! jq -ce '[.Notifications[] | {
    NotificationType,
    ComparisonOperator,
    Threshold,
    ThresholdType
  }]' "${budget_notifications_file}" >"${live_notifications_file}" ||
  ! policy_documents_match "${expected_notifications_file}" "${live_notifications_file}"; then
  fail "The live budget notifications differ from the reviewed contract."
fi

notification_number=0
while IFS= read -r notification; do
  notification_number=$((notification_number + 1))
  subscribers_file="${verification_dir}/budget-subscribers-${notification_number}.json"
  aws_json "${subscribers_file}" budgets describe-subscribers-for-notification \
    --account-id "${account_id}" \
    --budget-name "${budget_name}" \
    --notification "${notification}"
  jq -e --arg address "${budget_notification_email}" '
    .Subscribers == [{
      SubscriptionType: "EMAIL",
      Address: $address
    }]
  ' "${subscribers_file}" >/dev/null ||
    fail "A live budget notification subscriber differs from the independent reviewed contract."
done < <(jq -c '.[]' "${expected_notifications_file}")

if [[ "${verification_phase}" == "--before-removal" ]]; then
  policy_file="${verification_dir}/temporary-policy.json"
  entities_file="${verification_dir}/temporary-policy-entities.json"
  policy_version_file="${verification_dir}/temporary-policy-version.json"
  live_temporary_policy="${verification_dir}/live-temporary-policy.json"

  aws_iam_json "${policy_file}" iam get-policy --policy-arn "${temporary_policy_arn}"
  aws_iam_json "${entities_file}" iam list-entities-for-policy --policy-arn "${temporary_policy_arn}"
  default_version_id="$(jq -er '.Policy.DefaultVersionId | select(test("^v[1-9][0-9]*$"))' "${policy_file}")"
  aws_iam_json "${policy_version_file}" iam get-policy-version \
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
    ! policy_documents_match "${expected_temporary_policy}" "${live_temporary_policy}"; then
    fail "The attached temporary policy differs from the independent reviewed contract."
  fi
else
  temporary_policy_absent=false
  for ((attempt = 1; attempt <= iam_retry_attempts; attempt++)); do
    if aws --profile "${aws_profile}" iam get-policy \
      --policy-arn "${temporary_policy_arn}" \
      --output json >"${verification_dir}/deleted-policy.json" 2>"${aws_error_file}"; then
      if ((attempt < iam_retry_attempts)); then
        sleep "${iam_retry_delay_seconds}"
        continue
      fi
      fail "The temporary policy still exists after removal."
    fi

    if grep -Fq 'An error occurred (NoSuchEntity)' "${aws_error_file}"; then
      temporary_policy_absent=true
      break
    fi
    fail "The temporary policy deletion could not be verified."
  done

  [[ "${temporary_policy_absent}" == true ]] ||
    fail "The temporary policy deletion could not be verified."
fi

echo "Bootstrap access allow-list verification passed."
