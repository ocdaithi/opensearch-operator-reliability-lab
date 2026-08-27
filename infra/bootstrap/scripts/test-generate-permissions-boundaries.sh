#!/usr/bin/env bash
set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
test_root="$(cd "${test_root}" && pwd -P)"
trap 'rm -rf -- "${test_root}"' EXIT
account_id="$(printf '%06d%06d' 321 654)"
wrong_account_id="$(printf '%06d%06d' 999 111)"
negative_case_count=0

prepare_fixture() {
  local fixture_root="$1"

  mkdir -p \
    "${fixture_root}/infra/bootstrap/policies" \
    "${fixture_root}/infra/bootstrap/scripts"
  git -C "${fixture_root}" init -q
  cp "${source_root}/.gitignore" "${fixture_root}/.gitignore"
  cp "${source_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json" \
    "${fixture_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json"
  cp "${source_root}/infra/bootstrap/policies/github-actions-boundary.template.json" \
    "${fixture_root}/infra/bootstrap/policies/github-actions-boundary.template.json"
  cp "${source_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
    "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"
  cp "${source_root}/infra/bootstrap/scripts/policy-contract-digest.sh" \
    "${fixture_root}/infra/bootstrap/scripts/policy-contract-digest.sh"
}

assert_no_owned_artifacts() {
  local private_directory="$1"

  if compgen -G "${private_directory}/.terraform-admin-boundary.json.*" >/dev/null || \
    compgen -G "${private_directory}/.github-actions-boundary.json.*" >/dev/null; then
    echo "Permissions-boundary generation left an owned staging file." >&2
    exit 1
  fi
  if [[ -e "${private_directory}/.generate-permissions-boundaries.lock" || \
    -L "${private_directory}/.generate-permissions-boundaries.lock" ]]; then
    echo "Permissions-boundary generation left its invocation lock." >&2
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
generator_script="${test_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"

expect_generation_failure() {
  local case_name="$1"
  local expected_diagnostic="$2"
  local supplied_account_id="$3"
  local selected_generator="${4:-${generator_script}}"
  local generation_output

  if generation_output="$(AWS_ACCOUNT_ID="${supplied_account_id}" \
    "${selected_generator}" 2>&1)"; then
    echo "Permissions-boundary generation unexpectedly accepted: ${case_name}" >&2
    exit 1
  fi
  if [[ "${generation_output}" != "${expected_diagnostic}" ]]; then
    printf 'Permissions-boundary generation failed with an unexpected diagnostic for %s.\n' \
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

AWS_ACCOUNT_ID="${account_id}" \
  "${generator_script}" >/dev/null

private_dir="${test_root}/.private/terraform-bootstrap"
human_boundary="${private_dir}/terraform-admin-boundary.json"
github_boundary="${private_dir}/github-actions-boundary.json"
state_bucket_name="opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"

if stat -f '%Lp' "${private_dir}" >/dev/null 2>&1; then
  private_mode="$(stat -f '%Lp' "${private_dir}")"
else
  private_mode="$(stat -c '%a' "${private_dir}")"
fi
test "${private_mode}" = "700"

for boundary_file in "${human_boundary}" "${github_boundary}"; do
  test -s "${boundary_file}"
  git -C "${test_root}" check-ignore -q "${boundary_file}"

  if stat -f '%Lp' "${boundary_file}" >/dev/null 2>&1; then
    file_mode="$(stat -f '%Lp' "${boundary_file}")"
  else
    file_mode="$(stat -c '%a' "${boundary_file}")"
  fi
  test "${file_mode}" = "600"
  test "$(wc -c <"${boundary_file}" | tr -d '[:space:]')" -le 6144
done

if ! jq -e --arg account_id "${account_id}" --arg bucket "${state_bucket_name}" '
  def list: if type == "array" then sort else [.] end;
  def statement($sid):
    [.Statement[] | select(.Sid == $sid)]
    | if length == 1 then .[0] else null end;
  def ordinary_keys: (keys | sort) == ["Action", "Effect", "Resource", "Sid"];
  . as $policy
  | $policy.Version == "2012-10-17"
    and ($policy | keys | sort) == ["Statement", "Version"]
    and ($policy.Statement | length) == 11
    and ([$policy.Statement[].Sid] | sort) == [
      "AuditExactBootstrapUser",
      "DeleteReviewedTemporaryBootstrapPolicy",
      "DetachReviewedTemporaryBootstrapPolicy",
      "ManageBootstrapBudget",
      "ManageStateBucketControls",
      "ManageTerraformStateLock",
      "ReadAndWriteTerraformState",
      "ReadDefaultBillingViewData",
      "ReadExactBootstrapRoles",
      "ReadExactGitHubOIDCProvider",
      "ReadExactPermissionsBoundaries"
    ]
    and all($policy.Statement[]; .Effect == "Allow")
    and all($policy.Statement[]; has("NotAction") | not)
    and all($policy.Statement[]; has("NotResource") | not)
    and all($policy.Statement[]; (.Action | list | all(.[]; contains("*") | not)))
    and all($policy.Statement[]; (.Resource | list | all(.[]; . != "*")))
    and ([.. | strings | select(contains("__"))] | length == 0)
    and ($policy | statement("ReadAndWriteTerraformState") |
      ordinary_keys
      and (.Action | list) == ["s3:GetObject", "s3:PutObject"]
      and .Resource == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate"))
    and ($policy | statement("ManageTerraformStateLock") |
      ordinary_keys
      and (.Action | list) == ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
      and .Resource == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate.tflock"))
    and ($policy | statement("ManageStateBucketControls") |
      ordinary_keys
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
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketVersioning",
        "s3:PutEncryptionConfiguration",
        "s3:PutLifecycleConfiguration",
        "s3:TagResource",
        "s3:UntagResource"
      ]
      and .Resource == ("arn:aws:s3:::" + $bucket))
    and ($policy | statement("ManageBootstrapBudget") |
      ordinary_keys
      and (.Action | list) == [
        "budgets:ListTagsForResource",
        "budgets:ModifyBudget",
        "budgets:TagResource",
        "budgets:UntagResource",
        "budgets:ViewBudget"
      ]
      and .Resource == ("arn:aws:budgets::" + $account_id + ":budget/opensearch-lab-monthly-cost"))
    and ($policy | statement("ReadDefaultBillingViewData") |
      ordinary_keys
      and .Action == "billing:GetBillingViewData"
      and .Resource == ("arn:aws:billing::" + $account_id + ":billingview/primary"))
    and ($policy | statement("ReadExactBootstrapRoles") |
      ordinary_keys
      and (.Action | list) == [
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:ListRoleTags"
      ]
      and (.Resource | list) == [
        "arn:aws:iam::" + $account_id + ":role/opensearch-lab-github-actions",
        "arn:aws:iam::" + $account_id + ":role/opensearch-lab-terraform-admin"
      ])
    and ($policy | statement("ReadExactGitHubOIDCProvider") |
      ordinary_keys
      and (.Action | list) == ["iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviderTags"]
      and .Resource == ("arn:aws:iam::" + $account_id + ":oidc-provider/token.actions.githubusercontent.com"))
    and ($policy | statement("AuditExactBootstrapUser") |
      ordinary_keys
      and (.Action | list) == [
        "iam:GetUser",
        "iam:ListAccessKeys",
        "iam:ListAttachedUserPolicies",
        "iam:ListGroupsForUser",
        "iam:ListMFADevices",
        "iam:ListUserPolicies"
      ]
      and .Resource == ("arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap"))
    and ($policy | statement("ReadExactPermissionsBoundaries") |
      ordinary_keys
      and (.Action | list) == ["iam:GetPolicy", "iam:GetPolicyVersion"]
      and (.Resource | list) == [
        "arn:aws:iam::" + $account_id + ":policy/opensearch-lab-github-actions-boundary",
        "arn:aws:iam::" + $account_id + ":policy/opensearch-lab-terraform-admin-boundary"
      ])
    and ($policy | statement("DetachReviewedTemporaryBootstrapPolicy") |
      (keys | sort) == ["Action", "Condition", "Effect", "Resource", "Sid"]
      and .Action == "iam:DetachUserPolicy"
      and .Resource == ("arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap")
      and (.Condition | keys) == ["ArnEquals"]
      and (.Condition.ArnEquals | keys) == ["iam:PolicyARN"]
      and .Condition.ArnEquals["iam:PolicyARN"]
        == ("arn:aws:iam::" + $account_id + ":policy/opensearch-lab-temporary-bootstrap"))
    and ($policy | statement("DeleteReviewedTemporaryBootstrapPolicy") |
      ordinary_keys
      and (.Action | list) == [
        "iam:DeletePolicy",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:ListEntitiesForPolicy"
      ]
      and .Resource == ("arn:aws:iam::" + $account_id + ":policy/opensearch-lab-temporary-bootstrap"))
' "${human_boundary}" >/dev/null; then
  echo "Terraform administration boundary exact contract failed." >&2
  exit 1
fi

if ! jq -e --arg bucket "${state_bucket_name}" '
  def list: if type == "array" then sort else [.] end;
  def statement($sid):
    [.Statement[] | select(.Sid == $sid)]
    | if length == 1 then .[0] else null end;
  . as $policy
  | $policy.Version == "2012-10-17"
    and ($policy | keys | sort) == ["Statement", "Version"]
    and ($policy.Statement | length) == 3
    and ([$policy.Statement[].Sid] | sort) == [
      "ListExactTerraformStateKeys",
      "ManageTerraformStateLock",
      "ReadAndWriteTerraformState"
    ]
    and all($policy.Statement[]; .Effect == "Allow")
    and all($policy.Statement[]; has("NotAction") | not)
    and all($policy.Statement[]; has("NotResource") | not)
    and all($policy.Statement[]; (.Action | list | all(.[]; contains("*") | not)))
    and all($policy.Statement[]; (.Resource | list | all(.[]; . != "*")))
    and ([.. | strings | select(contains("__"))] | length == 0)
    and ($policy | statement("ListExactTerraformStateKeys") |
      (keys | sort) == ["Action", "Condition", "Effect", "Resource", "Sid"]
      and .Action == "s3:ListBucket"
      and .Resource == ("arn:aws:s3:::" + $bucket)
      and (.Condition | keys) == ["StringEquals"]
      and (.Condition.StringEquals | keys) == ["s3:prefix"]
      and (.Condition.StringEquals["s3:prefix"] | sort) == [
        "bootstrap/terraform.tfstate",
        "bootstrap/terraform.tfstate.tflock"
      ])
    and ($policy | statement("ReadAndWriteTerraformState") |
      (keys | sort) == ["Action", "Effect", "Resource", "Sid"]
      and (.Action | list) == ["s3:GetObject", "s3:PutObject"]
      and .Resource == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate"))
    and ($policy | statement("ManageTerraformStateLock") |
      (keys | sort) == ["Action", "Effect", "Resource", "Sid"]
      and (.Action | list) == ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
      and .Resource == ("arn:aws:s3:::" + $bucket + "/bootstrap/terraform.tfstate.tflock"))
' "${github_boundary}" >/dev/null; then
  echo "GitHub Actions boundary exact contract failed." >&2
  exit 1
fi

human_original="${test_root}/terraform-admin-boundary.original.json"
github_original="${test_root}/github-actions-boundary.original.json"
cp "${human_boundary}" "${human_original}"
cp "${github_boundary}" "${github_original}"
expect_generation_failure \
  "second-invocation" \
  "Refusing to overwrite existing destination: ${human_boundary}" \
  "${account_id}"
cmp -s "${human_original}" "${human_boundary}"
cmp -s "${github_original}" "${github_boundary}"
assert_no_owned_artifacts "${private_dir}"

exercise_existing_destination() {
  local destination_key="$1"
  local object_type="$2"
  local fixture_root
  local fixture_generator
  local fixture_private_dir
  local fixture_destination
  local other_destination
  local expected_diagnostic
  local referent
  local original
  local link_target

  fixture_root="$(mktemp -d \
    "${test_root}/existing-${destination_key}-${object_type}.XXXXXX")"
  prepare_fixture "${fixture_root}"
  fixture_generator="${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"
  fixture_private_dir="${fixture_root}/.private/terraform-bootstrap"
  mkdir -p "${fixture_private_dir}"

  case "${destination_key}" in
    human)
      fixture_destination="${fixture_private_dir}/terraform-admin-boundary.json"
      other_destination="${fixture_private_dir}/github-actions-boundary.json"
      ;;
    github)
      fixture_destination="${fixture_private_dir}/github-actions-boundary.json"
      other_destination="${fixture_private_dir}/terraform-admin-boundary.json"
      ;;
    *)
      echo "Unsupported boundary destination: ${destination_key}" >&2
      exit 1
      ;;
  esac
  expected_diagnostic="Refusing to overwrite existing destination: ${fixture_destination}"

  case "${object_type}" in
    regular-file)
      printf 'existing boundary bytes\n' >"${fixture_destination}"
      original="${fixture_root}/original-boundary"
      cp "${fixture_destination}" "${original}"
      ;;
    directory)
      mkdir "${fixture_destination}"
      printf 'directory marker\n' >"${fixture_destination}/marker"
      original="${fixture_root}/original-marker"
      cp "${fixture_destination}/marker" "${original}"
      ;;
    symlink)
      referent="${fixture_root}/boundary-referent"
      printf 'referent bytes\n' >"${referent}"
      original="${fixture_root}/original-referent"
      cp "${referent}" "${original}"
      ln -s "${referent}" "${fixture_destination}"
      link_target="$(readlink "${fixture_destination}")"
      ;;
    dangling-symlink)
      referent="${fixture_root}/missing-boundary-referent"
      ln -s "${referent}" "${fixture_destination}"
      link_target="$(readlink "${fixture_destination}")"
      ;;
    *)
      echo "Unsupported destination fixture type: ${object_type}" >&2
      exit 1
      ;;
  esac

  expect_generation_failure \
    "existing-${destination_key}-${object_type}" \
    "${expected_diagnostic}" \
    "${account_id}" \
    "${fixture_generator}"

  case "${object_type}" in
    regular-file)
      test -f "${fixture_destination}"
      cmp -s "${original}" "${fixture_destination}"
      ;;
    directory)
      test -d "${fixture_destination}"
      cmp -s "${original}" "${fixture_destination}/marker"
      ;;
    symlink)
      test -L "${fixture_destination}"
      test "$(readlink "${fixture_destination}")" = "${link_target}"
      cmp -s "${original}" "${referent}"
      ;;
    dangling-symlink)
      test -L "${fixture_destination}"
      test "$(readlink "${fixture_destination}")" = "${link_target}"
      test ! -e "${referent}"
      ;;
  esac

  test ! -e "${other_destination}"
  test ! -L "${other_destination}"
  assert_no_owned_artifacts "${fixture_private_dir}"
}

exercise_existing_destination "human" "regular-file"
exercise_existing_destination "github" "directory"
exercise_existing_destination "human" "symlink"
exercise_existing_destination "github" "dangling-symlink"

concurrent_fixture="$(mktemp -d "${test_root}/concurrent.XXXXXX")"
prepare_fixture "${concurrent_fixture}"
concurrent_generator="${concurrent_fixture}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"
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
  echo "Concurrent permissions-boundary generation did not produce exactly one winner." >&2
  exit 1
fi
concurrent_private_dir="${concurrent_fixture}/.private/terraform-bootstrap"
jq -e '.Version == "2012-10-17" and (.Statement | length) == 11' \
  "${concurrent_private_dir}/terraform-admin-boundary.json" >/dev/null
jq -e '.Version == "2012-10-17" and (.Statement | length) == 3' \
  "${concurrent_private_dir}/github-actions-boundary.json" >/dev/null
assert_no_owned_artifacts "${concurrent_private_dir}"
negative_case_count=$((negative_case_count + 1))
printf 'negative case: concurrent-invocation-loser\n'

publication_failure_fixture="$(mktemp -d "${test_root}/publication-failure.XXXXXX")"
prepare_fixture "${publication_failure_fixture}"
publication_failure_generator="${publication_failure_fixture}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"
publication_failure_private_dir="${publication_failure_fixture}/.private/terraform-bootstrap"
publication_failure_human="${publication_failure_private_dir}/terraform-admin-boundary.json"
publication_failure_github="${publication_failure_private_dir}/github-actions-boundary.json"
shim_directory="${publication_failure_fixture}/bin"
real_link="$(command -v link)"
mkdir "${shim_directory}"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "if [[ \"\${2:-}\" == */github-actions-boundary.json ]]; then" \
  '  exit 73' \
  'fi' \
  "exec \"\${REAL_LINK:?}\" \"\$@\"" >"${shim_directory}/link"
chmod 700 "${shim_directory}/link"
if publication_failure_diagnostic="$(PATH="${shim_directory}:${PATH}" \
  REAL_LINK="${real_link}" \
  AWS_ACCOUNT_ID="${account_id}" \
  "${publication_failure_generator}" 2>&1)"; then
  echo "Permissions-boundary generation unexpectedly survived partial publication." >&2
  exit 1
fi
if [[ "${publication_failure_diagnostic}" != \
  "Could not publish without overwriting destination: ${publication_failure_github}" ]]; then
  echo "Partial permissions-boundary publication produced an unexpected diagnostic." >&2
  exit 1
fi
test -s "${publication_failure_human}"
test ! -e "${publication_failure_github}"
test ! -L "${publication_failure_github}"
assert_no_owned_artifacts "${publication_failure_private_dir}"
partial_human_original="${publication_failure_fixture}/partial-human.original.json"
cp "${publication_failure_human}" "${partial_human_original}"
expect_generation_failure \
  "partial-publication-follow-up" \
  "Refusing to overwrite existing destination: ${publication_failure_human}" \
  "${account_id}" \
  "${publication_failure_generator}"
cmp -s "${partial_human_original}" "${publication_failure_human}"
test ! -e "${publication_failure_github}"
test ! -L "${publication_failure_github}"
assert_no_owned_artifacts "${publication_failure_private_dir}"

exercise_publication_race() {
  local destination_key="$1"
  local object_type="$2"
  local fixture_root
  local fixture_generator
  local fixture_private_dir
  local fixture_human
  local fixture_github
  local race_destination
  local other_destination
  local fixture_referent
  local referent_original
  local expected_marker
  local shim_directory
  local generation_output
  local real_link
  local real_ln

  fixture_root="$(mktemp -d \
    "${test_root}/publication-race-${destination_key}-${object_type}.XXXXXX")"
  prepare_fixture "${fixture_root}"
  fixture_generator="${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"
  fixture_private_dir="${fixture_root}/.private/terraform-bootstrap"
  fixture_human="${fixture_private_dir}/terraform-admin-boundary.json"
  fixture_github="${fixture_private_dir}/github-actions-boundary.json"
  fixture_referent="${fixture_root}/race-referent"
  expected_marker="${fixture_root}/expected-marker"
  shim_directory="${fixture_root}/bin"
  real_link="$(command -v link)"
  real_ln="$(command -v ln)"

  case "${destination_key}" in
    human)
      race_destination="${fixture_human}"
      other_destination="${fixture_github}"
      ;;
    github)
      race_destination="${fixture_github}"
      other_destination="${fixture_human}"
      ;;
    *)
      echo "Unsupported boundary race destination: ${destination_key}" >&2
      exit 1
      ;;
  esac

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
    RACE_DESTINATION="${race_destination}" \
    RACE_KIND="${object_type}" \
    RACE_REFERENT="${fixture_referent}" \
    AWS_ACCOUNT_ID="${account_id}" \
    "${fixture_generator}" 2>&1)"; then
    echo "Boundary generation accepted publication-time ${destination_key} ${object_type}." >&2
    exit 1
  fi
  if [[ "${generation_output}" != \
    "Could not publish without overwriting destination: ${race_destination}" ]]; then
    echo "Publication-time ${destination_key} ${object_type} produced an unexpected diagnostic." >&2
    exit 1
  fi

  case "${object_type}" in
    directory)
      test -d "${race_destination}"
      cmp -s "${expected_marker}" "${race_destination}/marker"
      assert_only_marker "${race_destination}"
      ;;
    symlink)
      test -L "${race_destination}"
      test "$(readlink "${race_destination}")" = "${fixture_referent}"
      cmp -s "${referent_original}" "${fixture_referent}/marker"
      assert_only_marker "${fixture_referent}"
      ;;
    *)
      echo "Unsupported publication race type: ${object_type}" >&2
      exit 1
      ;;
  esac

  if [[ "${destination_key}" == human ]]; then
    test ! -e "${other_destination}"
    test ! -L "${other_destination}"
  else
    jq -e '.Version == "2012-10-17" and (.Statement | length) == 11' \
      "${other_destination}" >/dev/null
  fi
  assert_no_owned_artifacts "${fixture_private_dir}"
  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: publication-race-%s-%s\n' \
    "${destination_key}" "${object_type}"
}

exercise_publication_race "human" "directory"
exercise_publication_race "github" "symlink"

pin_fixture_human_digest() {
  local fixture_root="$1"
  local fixture_template
  local fixture_generator
  local fixture_digest_helper
  local fixture_digest
  local updated_generator

  fixture_template="${fixture_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json"
  fixture_generator="${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"
  fixture_digest_helper="${fixture_root}/infra/bootstrap/scripts/policy-contract-digest.sh"
  fixture_digest="$("${fixture_digest_helper}" "${fixture_template}")"
  updated_generator="${fixture_generator}.updated"
  sed \
    "s/^human_template_digest=\"[0-9a-f]*\"$/human_template_digest=\"${fixture_digest}\"/" \
    "${fixture_generator}" >"${updated_generator}"
  mv "${updated_generator}" "${fixture_generator}"
  chmod 700 "${fixture_generator}"
  grep -Fq "human_template_digest=\"${fixture_digest}\"" "${fixture_generator}"
}

exercise_billing_resource_mutation() {
  local case_name="$1"
  local mutated_resource="$2"
  local fixture_root
  local fixture_template
  local fixture_generator
  local fixture_private_dir
  local fixture_human
  local fixture_github
  local mutated_template
  local generation_output

  fixture_root="$(mktemp -d "${test_root}/billing-${case_name}.XXXXXX")"
  prepare_fixture "${fixture_root}"
  fixture_template="${fixture_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json"
  fixture_generator="${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"
  fixture_private_dir="${fixture_root}/.private/terraform-bootstrap"
  fixture_human="${fixture_private_dir}/terraform-admin-boundary.json"
  fixture_github="${fixture_private_dir}/github-actions-boundary.json"
  mutated_template="${fixture_root}/mutated-template.json"
  jq --arg resource "${mutated_resource}" '
    (.Statement[] | select(.Sid == "ReadDefaultBillingViewData") | .Resource) = $resource
  ' "${fixture_template}" >"${mutated_template}"
  mv "${mutated_template}" "${fixture_template}"
  pin_fixture_human_digest "${fixture_root}"

  if generation_output="$(AWS_ACCOUNT_ID="${account_id}" \
    "${fixture_generator}" 2>&1)"; then
    echo "Permissions-boundary generation accepted billing mutation: ${case_name}" >&2
    exit 1
  fi
  if [[ "${generation_output}" != \
    "The Terraform administration boundary failed its billing-view invariant." ]]; then
    echo "Boundary billing mutation produced an unexpected diagnostic: ${case_name}" >&2
    exit 1
  fi
  test ! -e "${fixture_human}"
  test ! -L "${fixture_human}"
  test ! -e "${fixture_github}"
  test ! -L "${fixture_github}"
  assert_no_owned_artifacts "${fixture_private_dir}"
  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: billing-%s\n' "${case_name}"
}

exercise_billing_resource_mutation \
  "wildcard" \
  "*"
exercise_billing_resource_mutation \
  "prefix-wildcard" \
  "arn:__AWS_PARTITION__:billing::__AWS_ACCOUNT_ID__:billingview/*"
exercise_billing_resource_mutation \
  "wrong-account" \
  "arn:__AWS_PARTITION__:billing::${wrong_account_id}:billingview/primary"
exercise_billing_resource_mutation \
  "wrong-partition" \
  "arn:aws-us-gov:billing::__AWS_ACCOUNT_ID__:billingview/primary"
exercise_billing_resource_mutation \
  "custom-view" \
  "arn:__AWS_PARTITION__:billing::__AWS_ACCOUNT_ID__:billingview/custom"

mutated_template="${test_root}/infra/bootstrap/policies/github-actions-boundary.template.json.mutated"
jq '.Statement[0].Action = "iam:PutRolePermissionsBoundary"' \
  "${test_root}/infra/bootstrap/policies/github-actions-boundary.template.json" \
  >"${mutated_template}"
mv "${mutated_template}" \
  "${test_root}/infra/bootstrap/policies/github-actions-boundary.template.json"
jq -e '.Statement[0].Action == "iam:PutRolePermissionsBoundary"' \
  "${test_root}/infra/bootstrap/policies/github-actions-boundary.template.json" >/dev/null
expect_generation_failure \
  "boundary-mutation-permission" \
  "A permissions-boundary template differs from its exact reviewed contract." \
  "${account_id}"

printf 'Permissions boundary generation safeguards passed (%d negative cases).\n' \
  "${negative_case_count}"
