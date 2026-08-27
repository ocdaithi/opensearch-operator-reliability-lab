#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
test_root="$(cd "${test_root}" && pwd -P)"
trap 'rm -rf -- "${test_root}"' EXIT
account_id="$(printf '%06d%06d' 123 789)"
wrong_account_id="$(printf '%06d%06d' 999 111)"
negative_case_count=0

prepare_fixture() {
  local fixture_root="$1"

  mkdir -p \
    "${fixture_root}/infra/bootstrap/policies" \
    "${fixture_root}/infra/bootstrap/scripts"
  git -C "${fixture_root}" init -q
  cp "${source_root}/.gitignore" "${fixture_root}/.gitignore"
  cp "${source_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" \
    "${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
  cp "${source_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
    "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"
  cp "${source_root}/infra/bootstrap/scripts/policy-contract-digest.sh" \
    "${fixture_root}/infra/bootstrap/scripts/policy-contract-digest.sh"
}

assert_no_owned_artifacts() {
  local private_directory="$1"

  if compgen -G "${private_directory}/.temporary-bootstrap-policy.json.*" >/dev/null; then
    echo "Temporary policy generation left an owned staging file." >&2
    exit 1
  fi
  if [[ -e "${private_directory}/.generate-temporary-policy.lock" || \
    -L "${private_directory}/.generate-temporary-policy.lock" ]]; then
    echo "Temporary policy generation left its invocation lock." >&2
    exit 1
  fi
}

assert_only_marker() {
  local directory="$1"
  local -a entries=()

  shopt -s dotglob nullglob
  entries=("${directory}"/*)
  shopt -u dotglob nullglob
  if ((${#entries[@]} != 1)) || [[ "${entries[0]}" != "${directory}/marker" ]]; then
    echo "A publication race changed the destination directory contents." >&2
    exit 1
  fi
}

write_link_race_shim() {
  local shim_file="$1"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    "destination=\"\${2:?}\"" \
    "if [[ \"\${destination}\" == \"\${RACE_DESTINATION:?}\" ]]; then" \
    "  case \"\${RACE_KIND:?}\" in" \
    '    directory)' \
    "      mkdir \"\${destination}\"" \
    "      printf 'directory marker\\n' >\"\${destination}/marker\"" \
    '      ;;' \
    '    symlink)' \
    "      \"\${REAL_LN:?}\" -s \"\${RACE_REFERENT:?}\" \"\${destination}\"" \
    '      ;;' \
    '    *)' \
    '      exit 64' \
    '      ;;' \
    '  esac' \
    'fi' \
    "exec \"\${REAL_LINK:?}\" \"\$@\"" >"${shim_file}"
  chmod 700 "${shim_file}"
}

prepare_fixture "${test_root}"
generator_script="${test_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"

expect_generation_failure() {
  local case_name="$1"
  local expected_diagnostic="$2"
  local supplied_account_id="$3"
  local selected_generator="${4:-${generator_script}}"
  local generation_output

  if generation_output="$(AWS_ACCOUNT_ID="${supplied_account_id}" \
    "${selected_generator}" 2>&1)"; then
    echo "Temporary policy generation unexpectedly accepted: ${case_name}" >&2
    exit 1
  fi
  if [[ "${generation_output}" != "${expected_diagnostic}" ]]; then
    printf 'Temporary policy generation failed with an unexpected diagnostic for %s.\n' \
      "${case_name}" >&2
    printf 'Expected: %s\n' "${expected_diagnostic}" >&2
    printf 'Actual: %s\n' "${generation_output:-<no output>}" >&2
    exit 1
  fi
  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: %s\n' "${case_name}"
}

expect_generation_failure \
  "missing-account-id" \
  "AWS_ACCOUNT_ID must contain exactly 12 digits." \
  ""

generation_started="$(date -u +%s)"
AWS_ACCOUNT_ID="${account_id}" \
  "${generator_script}" >/dev/null
generation_finished="$(date -u +%s)"
resolved_policy="${test_root}/.private/terraform-bootstrap/temporary-bootstrap-policy.json"
state_bucket_name="opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"
minimum_expiry=$((generation_started + 14395))
maximum_expiry=$((generation_finished + 14405))

test -s "${resolved_policy}"
git -C "${test_root}" check-ignore -q "${resolved_policy}"

if stat -f '%Lp' "${resolved_policy}" >/dev/null 2>&1; then
  file_mode="$(stat -f '%Lp' "${resolved_policy}")"
else
  file_mode="$(stat -c '%a' "${resolved_policy}")"
fi
test "${file_mode}" = "600"

if ! jq -e \
  --arg account_id "${account_id}" \
  --arg bucket "${state_bucket_name}" \
  --argjson minimum_expiry "${minimum_expiry}" \
  --argjson maximum_expiry "${maximum_expiry}" '
  def list: if type == "array" then sort else [.] end;
  def statement($sid):
    [.Statement[] | select(.Sid == $sid)]
    | if length == 1 then .[0] else null end;
  def common_condition:
    .Condition.ArnEquals["aws:PrincipalArn"]
      == ("arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap")
    and .Condition.ArnLike["aws:SignInSessionArn"]
      == "arn:aws:signin:*:${aws:PrincipalAccount}:session/*"
    and (.Condition.DateLessThan["aws:CurrentTime"] | fromdateiso8601) >= $minimum_expiry
    and (.Condition.DateLessThan["aws:CurrentTime"] | fromdateiso8601) <= $maximum_expiry;
  def common_keys:
    (keys | sort) == ["Action", "Condition", "Effect", "Resource", "Sid"]
    and (.Condition | keys | sort) == ["ArnEquals", "ArnLike", "DateLessThan"]
    and (.Condition.ArnEquals | keys) == ["aws:PrincipalArn"];
  . as $policy
  | [.Statement[] | select(.Effect == "Allow")] as $allows
  | $policy.Version == "2012-10-17"
    and ($policy | keys | sort) == ["Statement", "Version"]
    and ($policy.Statement | length) == 11
    and ($allows | length) == 11
    and ([$allows[].Sid] | sort) == [
      "CreateAndTagExactStateBucket",
      "CreateGitHubRoleWithBoundary",
      "CreateHumanRoleWithBoundary",
      "ManageExactBootstrapBudget",
      "ManageExactGitHubOIDCProvider",
      "ManageStateBucketControls",
      "ManageTerraformStateLock",
      "ReadAndTagExactBootstrapRoles",
      "ReadAndWriteTerraformState",
      "ReadDefaultBillingViewData",
      "ReadExactBootstrapUser"
    ]
    and all($allows[]; common_condition)
    and ([$allows[].Condition.DateLessThan["aws:CurrentTime"]] | unique | length == 1)
    and all($allows[]; has("NotAction") | not)
    and all($allows[]; has("NotResource") | not)
    and all($allows[]; (.Action | list | all(.[]; contains("*") | not)))
    and all($allows[]; (.Resource | list | all(.[]; . != "*")))
    and ([.. | objects | keys[] | select(endswith("IfExists"))] | length == 0)
    and ([.. | strings | select(startswith("aws-portal:"))] | length == 0)
    and ([.. | strings | select(. == "iam:CreateServiceLinkedRole")] | length == 0)
    and ([.. | strings | select(contains("__"))] | length == 0)
    and ($policy | statement("CreateAndTagExactStateBucket") |
      common_keys
      and (.Action | list) == ["s3:CreateBucket", "s3:TagResource"]
      and .Resource == ("arn:aws:s3:::" + $bucket))
    and ($policy | statement("ManageStateBucketControls") |
      common_keys
      and (.Action | list) == [
        "s3:GetAccelerateConfiguration",
        "s3:GetBucketAcl",
        "s3:GetBucketCORS",
        "s3:GetBucketLocation",
        "s3:GetBucketLogging",
        "s3:GetBucketObjectLockConfiguration",
        "s3:GetBucketOwnershipControls",
        "s3:GetBucketPolicy",
        "s3:GetBucketPublicAccessBlock",
        "s3:GetBucketRequestPayment",
        "s3:GetBucketVersioning",
        "s3:GetBucketWebsite",
        "s3:GetEncryptionConfiguration",
        "s3:GetLifecycleConfiguration",
        "s3:GetReplicationConfiguration",
        "s3:ListBucket",
        "s3:ListTagsForResource",
        "s3:PutBucketOwnershipControls",
        "s3:PutBucketPolicy",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketVersioning",
        "s3:PutEncryptionConfiguration",
        "s3:PutLifecycleConfiguration",
        "s3:UntagResource"
      ]
      and .Resource == ("arn:aws:s3:::" + $bucket))
    and ($policy | statement("ReadAndWriteTerraformState") |
      common_keys
      and (.Action | list) == ["s3:GetObject", "s3:PutObject"]
      and .Resource == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate"))
    and ($policy | statement("ManageTerraformStateLock") |
      common_keys
      and (.Action | list) == ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
      and .Resource == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate.tflock"))
    and ($policy | statement("ManageExactBootstrapBudget") |
      common_keys
      and (.Action | list) == [
        "budgets:ListTagsForResource",
        "budgets:ModifyBudget",
        "budgets:TagResource",
        "budgets:UntagResource",
        "budgets:ViewBudget"
      ]
      and .Resource == ("arn:aws:budgets::" + $account_id + ":budget/opensearch-lab-monthly-cost"))
    and ($policy | statement("ReadDefaultBillingViewData") |
      common_keys
      and .Action == "billing:GetBillingViewData"
      and .Resource == ("arn:aws:billing::" + $account_id + ":billingview/primary"))
    and ($policy | statement("CreateHumanRoleWithBoundary") |
      (keys | sort) == ["Action", "Condition", "Effect", "Resource", "Sid"]
      and (.Condition | keys | sort) == ["ArnEquals", "ArnLike", "DateLessThan"]
      and (.Condition.ArnEquals | keys | sort) == [
        "aws:PrincipalArn",
        "iam:PermissionsBoundary"
      ]
      and (.Action | list) == ["iam:CreateRole", "iam:PutRolePolicy"]
      and .Resource == ("arn:aws:iam::" + $account_id + ":role/opensearch-lab-terraform-admin")
      and .Condition.ArnEquals["iam:PermissionsBoundary"]
        == ("arn:aws:iam::" + $account_id + ":policy/opensearch-lab-terraform-admin-boundary"))
    and ($policy | statement("CreateGitHubRoleWithBoundary") |
      (keys | sort) == ["Action", "Condition", "Effect", "Resource", "Sid"]
      and (.Condition | keys | sort) == ["ArnEquals", "ArnLike", "DateLessThan"]
      and (.Condition.ArnEquals | keys | sort) == [
        "aws:PrincipalArn",
        "iam:PermissionsBoundary"
      ]
      and (.Action | list) == ["iam:CreateRole", "iam:PutRolePolicy"]
      and .Resource == ("arn:aws:iam::" + $account_id + ":role/opensearch-lab-github-actions")
      and .Condition.ArnEquals["iam:PermissionsBoundary"]
        == ("arn:aws:iam::" + $account_id + ":policy/opensearch-lab-github-actions-boundary"))
    and ($policy | statement("ReadAndTagExactBootstrapRoles") |
      common_keys
      and (.Action | list) == [
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:ListRoleTags",
        "iam:TagRole"
      ]
      and (.Resource | list) == [
        "arn:aws:iam::" + $account_id + ":role/opensearch-lab-github-actions",
        "arn:aws:iam::" + $account_id + ":role/opensearch-lab-terraform-admin"
      ])
    and ($policy | statement("ManageExactGitHubOIDCProvider") |
      common_keys
      and (.Action | list) == [
        "iam:CreateOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider",
        "iam:ListOpenIDConnectProviderTags",
        "iam:TagOpenIDConnectProvider"
      ]
      and .Resource == ("arn:aws:iam::" + $account_id + ":oidc-provider/token.actions.githubusercontent.com"))
    and ($policy | statement("ReadExactBootstrapUser") |
      common_keys
      and .Action == "iam:GetUser"
      and .Resource == ("arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap"))
' "${resolved_policy}" >/dev/null; then
  echo "Temporary policy exact contract failed." >&2
  exit 1
fi

test "$(wc -c <"${resolved_policy}" | tr -d '[:space:]')" -le 6144

original_policy="${test_root}/temporary-bootstrap-policy.original.json"
cp "${resolved_policy}" "${original_policy}"
expect_generation_failure \
  "second-invocation" \
  "Refusing to overwrite existing destination: ${resolved_policy}" \
  "${account_id}"
cmp -s "${original_policy}" "${resolved_policy}"
assert_no_owned_artifacts "${test_root}/.private/terraform-bootstrap"

exercise_existing_destination() {
  local object_type="$1"
  local fixture_root
  local fixture_generator
  local fixture_private_dir
  local fixture_output
  local expected_diagnostic
  local referent
  local original
  local link_target

  fixture_root="$(mktemp -d "${test_root}/existing-${object_type}.XXXXXX")"
  prepare_fixture "${fixture_root}"
  fixture_generator="${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"
  fixture_private_dir="${fixture_root}/.private/terraform-bootstrap"
  fixture_output="${fixture_private_dir}/temporary-bootstrap-policy.json"
  expected_diagnostic="Refusing to overwrite existing destination: ${fixture_output}"
  mkdir -p "${fixture_private_dir}"

  case "${object_type}" in
    regular-file)
      printf 'existing policy bytes\n' >"${fixture_output}"
      original="${fixture_root}/original-policy"
      cp "${fixture_output}" "${original}"
      ;;
    directory)
      mkdir "${fixture_output}"
      printf 'directory marker\n' >"${fixture_output}/marker"
      original="${fixture_root}/original-marker"
      cp "${fixture_output}/marker" "${original}"
      ;;
    symlink)
      referent="${fixture_root}/policy-referent"
      printf 'referent bytes\n' >"${referent}"
      original="${fixture_root}/original-referent"
      cp "${referent}" "${original}"
      ln -s "${referent}" "${fixture_output}"
      link_target="$(readlink "${fixture_output}")"
      ;;
    dangling-symlink)
      referent="${fixture_root}/missing-policy-referent"
      ln -s "${referent}" "${fixture_output}"
      link_target="$(readlink "${fixture_output}")"
      ;;
    *)
      echo "Unsupported destination fixture type: ${object_type}" >&2
      exit 1
      ;;
  esac

  expect_generation_failure \
    "existing-${object_type}" \
    "${expected_diagnostic}" \
    "${account_id}" \
    "${fixture_generator}"

  case "${object_type}" in
    regular-file)
      test -f "${fixture_output}"
      cmp -s "${original}" "${fixture_output}"
      ;;
    directory)
      test -d "${fixture_output}"
      cmp -s "${original}" "${fixture_output}/marker"
      ;;
    symlink)
      test -L "${fixture_output}"
      test "$(readlink "${fixture_output}")" = "${link_target}"
      cmp -s "${original}" "${referent}"
      ;;
    dangling-symlink)
      test -L "${fixture_output}"
      test "$(readlink "${fixture_output}")" = "${link_target}"
      test ! -e "${referent}"
      ;;
  esac

  assert_no_owned_artifacts "${fixture_private_dir}"
}

exercise_existing_destination "regular-file"
exercise_existing_destination "directory"
exercise_existing_destination "symlink"
exercise_existing_destination "dangling-symlink"

concurrent_fixture="$(mktemp -d "${test_root}/concurrent.XXXXXX")"
prepare_fixture "${concurrent_fixture}"
concurrent_generator="${concurrent_fixture}/infra/bootstrap/scripts/generate-temporary-policy.sh"
AWS_ACCOUNT_ID="${account_id}" \
  "${concurrent_generator}" >"${concurrent_fixture}/first.log" 2>&1 &
first_pid=$!
AWS_ACCOUNT_ID="${account_id}" \
  "${concurrent_generator}" >"${concurrent_fixture}/second.log" 2>&1 &
second_pid=$!
if wait "${first_pid}"; then
  first_status=0
else
  first_status=$?
fi
if wait "${second_pid}"; then
  second_status=0
else
  second_status=$?
fi
if ! { ((first_status == 0 && second_status != 0)) || \
  ((first_status != 0 && second_status == 0)); }; then
  echo "Concurrent temporary-policy generation did not produce exactly one winner." >&2
  exit 1
fi
concurrent_private_dir="${concurrent_fixture}/.private/terraform-bootstrap"
concurrent_output="${concurrent_private_dir}/temporary-bootstrap-policy.json"
jq -e '.Version == "2012-10-17" and (.Statement | length) == 11' \
  "${concurrent_output}" >/dev/null
assert_no_owned_artifacts "${concurrent_private_dir}"
negative_case_count=$((negative_case_count + 1))
printf 'negative case: concurrent-invocation-loser\n'

publication_failure_fixture="$(mktemp -d "${test_root}/publication-failure.XXXXXX")"
prepare_fixture "${publication_failure_fixture}"
publication_failure_generator="${publication_failure_fixture}/infra/bootstrap/scripts/generate-temporary-policy.sh"
publication_failure_private_dir="${publication_failure_fixture}/.private/terraform-bootstrap"
publication_failure_output="${publication_failure_private_dir}/temporary-bootstrap-policy.json"
shim_directory="${publication_failure_fixture}/bin"
mkdir "${shim_directory}"
printf '%s\n' '#!/usr/bin/env bash' 'exit 73' >"${shim_directory}/link"
chmod 700 "${shim_directory}/link"
if publication_failure_diagnostic="$(PATH="${shim_directory}:${PATH}" \
  AWS_ACCOUNT_ID="${account_id}" \
  "${publication_failure_generator}" 2>&1)"; then
  echo "Temporary policy generation unexpectedly survived publication failure." >&2
  exit 1
fi
if [[ "${publication_failure_diagnostic}" != \
  "Could not publish without overwriting destination: ${publication_failure_output}" ]]; then
  echo "Temporary policy publication failure produced an unexpected diagnostic." >&2
  exit 1
fi
test ! -e "${publication_failure_output}"
test ! -L "${publication_failure_output}"
assert_no_owned_artifacts "${publication_failure_private_dir}"
negative_case_count=$((negative_case_count + 1))
printf 'negative case: exclusive-publication-failure\n'

exercise_publication_race() {
  local object_type="$1"
  local fixture_root
  local fixture_generator
  local fixture_private_dir
  local fixture_output
  local fixture_referent
  local referent_original
  local expected_marker
  local shim_directory
  local generation_output
  local real_link
  local real_ln

  fixture_root="$(mktemp -d "${test_root}/publication-race-${object_type}.XXXXXX")"
  prepare_fixture "${fixture_root}"
  fixture_generator="${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"
  fixture_private_dir="${fixture_root}/.private/terraform-bootstrap"
  fixture_output="${fixture_private_dir}/temporary-bootstrap-policy.json"
  fixture_referent="${fixture_root}/race-referent"
  expected_marker="${fixture_root}/expected-marker"
  shim_directory="${fixture_root}/bin"
  real_link="$(command -v link)"
  real_ln="$(command -v ln)"
  mkdir "${shim_directory}"
  write_link_race_shim "${shim_directory}/link"
  printf 'directory marker\n' >"${expected_marker}"

  if [[ "${object_type}" == symlink ]]; then
    mkdir "${fixture_referent}"
    printf 'referent marker\n' >"${fixture_referent}/marker"
    referent_original="${fixture_root}/referent-marker.original"
    cp "${fixture_referent}/marker" "${referent_original}"
  fi

  if generation_output="$(PATH="${shim_directory}:${PATH}" \
    REAL_LINK="${real_link}" \
    REAL_LN="${real_ln}" \
    RACE_DESTINATION="${fixture_output}" \
    RACE_KIND="${object_type}" \
    RACE_REFERENT="${fixture_referent}" \
    AWS_ACCOUNT_ID="${account_id}" \
    "${fixture_generator}" 2>&1)"; then
    echo "Temporary policy generation accepted publication-time ${object_type}." >&2
    exit 1
  fi
  if [[ "${generation_output}" != \
    "Could not publish without overwriting destination: ${fixture_output}" ]]; then
    echo "Publication-time ${object_type} produced an unexpected diagnostic." >&2
    exit 1
  fi

  case "${object_type}" in
    directory)
      test -d "${fixture_output}"
      cmp -s "${expected_marker}" "${fixture_output}/marker"
      assert_only_marker "${fixture_output}"
      ;;
    symlink)
      test -L "${fixture_output}"
      test "$(readlink "${fixture_output}")" = "${fixture_referent}"
      cmp -s "${referent_original}" "${fixture_referent}/marker"
      assert_only_marker "${fixture_referent}"
      ;;
    *)
      echo "Unsupported publication race type: ${object_type}" >&2
      exit 1
      ;;
  esac

  assert_no_owned_artifacts "${fixture_private_dir}"
  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: publication-race-%s\n' "${object_type}"
}

exercise_publication_race "directory"
exercise_publication_race "symlink"

pin_fixture_template_digest() {
  local fixture_root="$1"
  local fixture_template
  local fixture_generator
  local fixture_digest_helper
  local fixture_digest
  local updated_generator

  fixture_template="${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
  fixture_generator="${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"
  fixture_digest_helper="${fixture_root}/infra/bootstrap/scripts/policy-contract-digest.sh"
  fixture_digest="$("${fixture_digest_helper}" "${fixture_template}")"
  updated_generator="${fixture_generator}.updated"
  sed \
    "s/^reviewed_template_digest=\"[0-9a-f]*\"$/reviewed_template_digest=\"${fixture_digest}\"/" \
    "${fixture_generator}" >"${updated_generator}"
  mv "${updated_generator}" "${fixture_generator}"
  chmod 700 "${fixture_generator}"
  grep -Fq "reviewed_template_digest=\"${fixture_digest}\"" "${fixture_generator}"
}

exercise_billing_resource_mutation() {
  local case_name="$1"
  local mutated_resource="$2"
  local fixture_root
  local fixture_template
  local fixture_generator
  local fixture_private_dir
  local fixture_output
  local mutated_template
  local generation_output

  fixture_root="$(mktemp -d "${test_root}/billing-${case_name}.XXXXXX")"
  prepare_fixture "${fixture_root}"
  fixture_template="${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
  fixture_generator="${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"
  fixture_private_dir="${fixture_root}/.private/terraform-bootstrap"
  fixture_output="${fixture_private_dir}/temporary-bootstrap-policy.json"
  mutated_template="${fixture_root}/mutated-template.json"
  jq --arg resource "${mutated_resource}" '
    (.Statement[] | select(.Sid == "ReadDefaultBillingViewData") | .Resource) = $resource
  ' "${fixture_template}" >"${mutated_template}"
  mv "${mutated_template}" "${fixture_template}"
  pin_fixture_template_digest "${fixture_root}"

  if generation_output="$(AWS_ACCOUNT_ID="${account_id}" \
    "${fixture_generator}" 2>&1)"; then
    echo "Temporary policy generation accepted billing mutation: ${case_name}" >&2
    exit 1
  fi
  if [[ "${generation_output}" != \
    "The temporary policy template failed its security invariants." ]]; then
    echo "Temporary policy billing mutation produced an unexpected diagnostic: ${case_name}" >&2
    exit 1
  fi
  test ! -e "${fixture_output}"
  test ! -L "${fixture_output}"
  assert_no_owned_artifacts "${fixture_private_dir}"
  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: billing-%s\n' "${case_name}"
}

exercise_billing_resource_mutation \
  "wildcard" \
  "*"
exercise_billing_resource_mutation \
  "prefix-wildcard" \
  "arn:aws:billing::__AWS_ACCOUNT_ID__:billingview/*"
exercise_billing_resource_mutation \
  "wrong-account" \
  "arn:aws:billing::${wrong_account_id}:billingview/primary"
exercise_billing_resource_mutation \
  "wrong-partition" \
  "arn:aws-us-gov:billing::__AWS_ACCOUNT_ID__:billingview/primary"
exercise_billing_resource_mutation \
  "custom-view" \
  "arn:aws:billing::__AWS_ACCOUNT_ID__:billingview/custom"

exercise_principal_arn_mutation() {
  local case_name="$1"
  local fixture_root
  local fixture_template
  local fixture_generator
  local fixture_private_dir
  local fixture_output
  local mutated_template
  local generation_output

  fixture_root="$(mktemp -d "${test_root}/principal-${case_name}.XXXXXX")"
  prepare_fixture "${fixture_root}"
  fixture_template="${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
  fixture_generator="${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"
  fixture_private_dir="${fixture_root}/.private/terraform-bootstrap"
  fixture_output="${fixture_private_dir}/temporary-bootstrap-policy.json"
  mutated_template="${fixture_root}/mutated-template.json"

  case "${case_name}" in
    missing)
      jq 'del(.Statement[].Condition.ArnEquals["aws:PrincipalArn"])' \
        "${fixture_template}" >"${mutated_template}"
      ;;
    wildcard)
      jq '(.Statement[].Condition.ArnEquals["aws:PrincipalArn"])
        = "arn:aws:iam::__AWS_ACCOUNT_ID__:user/*"' \
        "${fixture_template}" >"${mutated_template}"
      ;;
    wrong-path)
      jq '(.Statement[].Condition.ArnEquals["aws:PrincipalArn"])
        = "arn:aws:iam::__AWS_ACCOUNT_ID__:user/bootstrap/opensearch-lab-bootstrap"' \
        "${fixture_template}" >"${mutated_template}"
      ;;
    if-exists)
      jq '(.Statement[].Condition) |= (
        .ArnEqualsIfExists = {
          "aws:PrincipalArn": .ArnEquals["aws:PrincipalArn"]
        }
        | del(.ArnEquals["aws:PrincipalArn"])
      )' "${fixture_template}" >"${mutated_template}"
      ;;
    *)
      echo "Unsupported principal ARN mutation: ${case_name}" >&2
      exit 1
      ;;
  esac

  mv "${mutated_template}" "${fixture_template}"
  pin_fixture_template_digest "${fixture_root}"
  if generation_output="$(AWS_ACCOUNT_ID="${account_id}" \
    "${fixture_generator}" 2>&1)"; then
    echo "Temporary policy generation accepted PrincipalArn mutation: ${case_name}" >&2
    exit 1
  fi
  if [[ "${generation_output}" != \
    "The temporary policy template failed its security invariants." ]]; then
    echo "Temporary policy PrincipalArn mutation produced an unexpected diagnostic: ${case_name}" >&2
    exit 1
  fi
  test ! -e "${fixture_output}"
  test ! -L "${fixture_output}"
  assert_no_owned_artifacts "${fixture_private_dir}"
  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: principal-arn-%s\n' "${case_name}"
}

exercise_principal_arn_mutation "missing"
exercise_principal_arn_mutation "wildcard"
exercise_principal_arn_mutation "wrong-path"
exercise_principal_arn_mutation "if-exists"

pristine_template="${test_root}/temporary-bootstrap-policy.pristine.json"
cp "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" \
  "${pristine_template}"

mutated_template="${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json.mutated"
jq '.Statement += [{
  "Sid": "UnexpectedDeny",
  "Effect": "Deny",
  "NotAction": "iam:GetUser",
  "NotResource": "arn:aws:iam::__AWS_ACCOUNT_ID__:user/opensearch-lab-bootstrap"
}]' "${pristine_template}" >"${mutated_template}"
mv "${mutated_template}" \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
jq -e 'any(.Statement[]; .Sid == "UnexpectedDeny" and has("NotAction") and has("NotResource"))' \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" >/dev/null
expect_generation_failure \
  "unexpected-deny-statement" \
  "The temporary policy template differs from its exact reviewed contract." \
  "${account_id}"

cp "${pristine_template}" \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
mutated_template="${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json.mutated"
jq '.Statement[0].Action += ["iam:PutRolePermissionsBoundary"]' \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" \
  >"${mutated_template}"
mv "${mutated_template}" \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
jq -e '.Statement[0].Action | index("iam:PutRolePermissionsBoundary") != null' \
  "${test_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" >/dev/null
expect_generation_failure \
  "boundary-mutation-permission" \
  "The temporary policy template differs from its exact reviewed contract." \
  "${account_id}"

printf 'Temporary policy generation safeguards passed (%d negative cases).\n' \
  "${negative_case_count}"
