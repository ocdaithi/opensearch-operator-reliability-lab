#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
account_id="$(printf '%06d%06d' 123 456)"
state_bucket_name="opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"
terraform_admin_role_arn="arn:aws:iam::${account_id}:role/opensearch-lab-terraform-admin"
fixture_root="${test_root}/fixture"
negative_case_count=0

mkdir -p \
  "${fixture_root}/bin" \
  "${fixture_root}/infra/bootstrap/policies" \
  "${fixture_root}/infra/bootstrap/scripts"
git -C "${fixture_root}" init -q
cp "${source_root}/.gitignore" "${fixture_root}/.gitignore"
cp "${source_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" \
  "${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
cp "${source_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json" \
  "${fixture_root}/infra/bootstrap/policies/terraform-admin-boundary.template.json"
cp "${source_root}/infra/bootstrap/policies/github-actions-boundary.template.json" \
  "${fixture_root}/infra/bootstrap/policies/github-actions-boundary.template.json"
cp "${source_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"
cp "${source_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh"
cp "${source_root}/infra/bootstrap/scripts/policy-contract-digest.sh" \
  "${fixture_root}/infra/bootstrap/scripts/policy-contract-digest.sh"
cp "${source_root}/infra/bootstrap/scripts/verify-bootstrap-access.sh" \
  "${fixture_root}/infra/bootstrap/scripts/verify-bootstrap-access.sh"
cp "${source_root}/infra/bootstrap/scripts/check-backend-contract.sh" \
  "${fixture_root}/infra/bootstrap/scripts/check-backend-contract.sh"
cat >"${fixture_root}/infra/bootstrap/backend.tf" <<EOF
terraform {
  backend "s3" {
    bucket       = "${state_bucket_name}"
    key          = "bootstrap/terraform.tfstate"
    profile      = "opensearch-lab-terraform"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true

    assume_role = {
      role_arn     = "${terraform_admin_role_arn}"
      session_name = "terraform-bootstrap-state"
    }
  }
}
EOF

AWS_ACCOUNT_ID="${account_id}" \
  "${fixture_root}/infra/bootstrap/scripts/generate-permissions-boundaries.sh" >/dev/null

jq -n \
  --arg account_id "${account_id}" \
  --arg state_bucket_name "${state_bucket_name}" \
  --slurpfile github_boundary "${fixture_root}/.private/terraform-bootstrap/github-actions-boundary.json" \
  --slurpfile human_boundary "${fixture_root}/.private/terraform-bootstrap/terraform-admin-boundary.json" '
  {
    human_boundary: $human_boundary[0],
    human_boundary_arn: (
      "arn:aws:iam::" + $account_id
      + ":policy/opensearch-lab-terraform-admin-boundary"
    ),
    github_boundary: $github_boundary[0],
    github_boundary_arn: (
      "arn:aws:iam::" + $account_id
      + ":policy/opensearch-lab-github-actions-boundary"
    ),
    human_trust: {
      Version: "2012-10-17",
      Statement: [{
        Sid: "AllowExactBootstrapUser",
        Effect: "Allow",
        Action: "sts:AssumeRole",
        Principal: {
          AWS: ("arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap")
        },
        Condition: {
          ArnLike: {
            "aws:SignInSessionArn": (
              "arn:aws:signin:*:" + $account_id + ":session/*"
            )
          }
        }
      }]
    },
    human_inline: {
      Version: "2012-10-17",
      Statement: [{
        Sid: "SyntheticHumanAccess",
        Effect: "Allow",
        Action: "s3:ListBucket",
        Resource: "arn:aws:s3:::opensearch-lab-tfstate-synthetic"
      }]
    },
    github_trust: {
      Version: "2012-10-17",
      Statement: [{
        Sid: "AllowExactRepositoryEnvironment",
        Effect: "Allow",
        Action: "sts:AssumeRoleWithWebIdentity",
        Principal: {
          Federated: (
            "arn:aws:iam::" + $account_id
            + ":oidc-provider/token.actions.githubusercontent.com"
          )
        },
        Condition: {
          StringEquals: {
            "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
            "token.actions.githubusercontent.com:sub": (
              "repo:ocdaithi@321047870/"
              + "opensearch-operator-reliability-lab@1346323330:"
              + "environment:aws-bootstrap"
            )
          }
        }
      }]
    },
    github_inline: {
      Version: "2012-10-17",
      Statement: [{
        Sid: "SyntheticStateAccess",
        Effect: "Allow",
        Action: "s3:GetObject",
        Resource: "arn:aws:s3:::opensearch-lab-tfstate-synthetic/bootstrap/terraform.tfstate"
      }]
    },
    state_bucket_name: $state_bucket_name,
    state_bucket_policy: {
      Version: "2012-10-17",
      Statement: [{
        Sid: "DenyInsecureTransport",
        Effect: "Deny",
        Action: "s3:*",
        Principal: "*",
        Resource: [
          ("arn:aws:s3:::" + $state_bucket_name),
          ("arn:aws:s3:::" + $state_bucket_name + "/*")
        ],
        Condition: {
          Bool: {
            "aws:SecureTransport": "false"
          }
        }
      }]
    },
    oidc_url: "token.actions.githubusercontent.com",
    oidc_audiences: ["sts.amazonaws.com"],
    oidc_provider_arn: (
      "arn:aws:iam::" + $account_id
      + ":oidc-provider/token.actions.githubusercontent.com"
    )
  }
' >"${fixture_root}/expected-documents.json"

cat >"${fixture_root}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" != *" show -json"* ]]; then
  exit 1
fi

jq -nc --slurpfile documents "${FAKE_FIXTURE_ROOT}/expected-documents.json" '
  $documents[0] as $documents
  | {
      format_version: "1.0",
      values: {
        root_module: {
          resources: [
            {
              address: "aws_iam_role.terraform_admin",
              values: {
                assume_role_policy: ($documents.human_trust | tojson),
                permissions_boundary: $documents.human_boundary_arn
              }
            },
            {
              address: "aws_iam_role_policy.terraform_admin",
              values: {policy: ($documents.human_inline | tojson)}
            },
            {
              address: "aws_iam_role.github_actions",
              values: {
                assume_role_policy: ($documents.github_trust | tojson),
                permissions_boundary: $documents.github_boundary_arn
              }
            },
            {
              address: "aws_iam_role_policy.github_actions_state",
              values: {policy: ($documents.github_inline | tojson)}
            },
            {
              address: "aws_iam_openid_connect_provider.github",
              values: {
                arn: $documents.oidc_provider_arn,
                client_id_list: $documents.oidc_audiences,
                url: $documents.oidc_url
              }
            },
            {
              address: "aws_s3_bucket.state",
              values: {bucket: $documents.state_bucket_name}
            },
            {
              address: "aws_s3_bucket_policy.state",
              values: {policy: ($documents.state_bucket_policy | tojson)}
            }
          ]
        }
      }
    }
  '
EOF

cat >"${fixture_root}/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

documents_file="${FAKE_FIXTURE_ROOT}/expected-documents.json"
account_id="${FAKE_ACCOUNT_ID}"
temporary_policy="${FAKE_FIXTURE_ROOT}/.private/terraform-bootstrap/temporary-bootstrap-policy.json"

case "$*" in
  *" s3api get-bucket-policy "*)
    if [[ "${FAKE_SCENARIO:-}" == "changed-bucket-policy" ]]; then
      jq -c '.state_bucket_policy.Statement += [{Sid:"Unexpected",Effect:"Allow",Action:"s3:GetObject",Principal:"*",Resource:"*"}] | {Policy:(.state_bucket_policy | tojson)}' \
        "${documents_file}"
    elif [[ "${FAKE_SCENARIO:-}" == "reordered-policy-documents" ]]; then
      jq -c '
        def reordered:
          if type == "object" then
            to_entries | reverse | map(.value |= reordered) | from_entries
          elif type == "array" then
            map(reordered) | reverse
          else
            .
          end;
        {Policy:(.state_bucket_policy | reordered | tojson)}
      ' "${documents_file}"
    else
      jq -c '{Policy:(.state_bucket_policy | tojson)}' "${documents_file}"
    fi
    ;;
  *" sts get-caller-identity "*)
    if [[ "${FAKE_SCENARIO:-}" == "wrong-caller-role" ]]; then
      caller_role="opensearch-lab-github-actions"
    else
      caller_role="opensearch-lab-terraform-admin"
    fi
    jq -nc --arg account_id "${account_id}" --arg caller_role "${caller_role}" '{
      Account: $account_id,
      Arn: (
        "arn:aws:sts::" + $account_id
        + ":assumed-role/" + $caller_role + "/verification"
      ),
      UserId: "synthetic"
    }'
    ;;
  *" iam get-user "*)
    if [[ "${FAKE_SCENARIO:-}" == "user-boundary" ]]; then
      jq -nc '{User:{UserName:"opensearch-lab-bootstrap",PermissionsBoundary:{}}}'
    else
      jq -nc '{User:{UserName:"opensearch-lab-bootstrap"}}'
    fi
    ;;
  *" iam list-access-keys "*)
    if [[ "${FAKE_SCENARIO:-}" == "access-key" ]]; then
      jq -nc '{AccessKeyMetadata:[{}]}'
    else
      jq -nc '{AccessKeyMetadata:[]}'
    fi
    ;;
  *" iam list-groups-for-user "*)
    if [[ "${FAKE_SCENARIO:-}" == "group" ]]; then
      jq -nc '{Groups:[{GroupName:"unexpected"}]}'
    else
      jq -nc '{Groups:[]}'
    fi
    ;;
  *" iam list-mfa-devices "*)
    if [[ "${FAKE_SCENARIO:-}" == "missing-mfa" ]]; then
      jq -nc '{MFADevices:[]}'
    else
      jq -nc '{MFADevices:[{UserName:"opensearch-lab-bootstrap",SerialNumber:"synthetic"}]}'
    fi
    ;;
  *" iam list-attached-user-policies "*)
    jq -nc \
      --arg account_id "${account_id}" \
      --arg phase "${FAKE_PHASE}" \
      --arg scenario "${FAKE_SCENARIO:-}" '
        [{
          PolicyName: "SignInLocalDevelopmentAccess",
          PolicyArn: "arn:aws:iam::aws:policy/SignInLocalDevelopmentAccess"
        }]
        + if $phase == "before" then [{
            PolicyName: "opensearch-lab-temporary-bootstrap",
            PolicyArn: (
              "arn:aws:iam::" + $account_id
              + ":policy/opensearch-lab-temporary-bootstrap"
            )
          }] else [] end
        + if $scenario == "extra-user-policy" then [{
            PolicyName: "unexpected",
            PolicyArn: ("arn:aws:iam::" + $account_id + ":policy/unexpected")
          }] else [] end
        | {AttachedPolicies: .}
      '
    ;;
  *" iam list-user-policies "*)
    if [[ "${FAKE_SCENARIO:-}" == "extra-user-inline" ]]; then
      jq -nc '{PolicyNames:["unexpected"]}'
    else
      jq -nc '{PolicyNames:[]}'
    fi
    ;;
  *" iam get-role-policy "*)
    if [[ "${FAKE_SCENARIO:-}" == "changed-role-inline-policy" ]] &&
      [[ "$*" == *"opensearch-lab-github-actions"* ]]; then
      jq -c '.github_inline.Statement[0].Action = ["s3:GetObject", "s3:GetObjectVersion"] | {PolicyDocument:.github_inline}' \
        "${documents_file}"
    elif [[ "${FAKE_SCENARIO:-}" == "reordered-policy-documents" ]]; then
      if [[ "$*" == *"opensearch-lab-terraform-admin"* ]]; then
        policy_key="human_inline"
      else
        policy_key="github_inline"
      fi
      jq -c --arg policy_key "${policy_key}" '
        def reordered:
          if type == "object" then
            to_entries | reverse | map(.value |= reordered) | from_entries
          elif type == "array" then
            map(reordered) | reverse
          else
            .
          end;
        {PolicyDocument:(.[$policy_key] | reordered)}
      ' "${documents_file}"
    elif [[ "$*" == *"opensearch-lab-terraform-admin"* ]]; then
      jq -c '{PolicyDocument:.human_inline}' "${documents_file}"
    else
      jq -c '{PolicyDocument:.github_inline}' "${documents_file}"
    fi
    ;;
  *" iam list-attached-role-policies "*)
    if [[ "${FAKE_SCENARIO:-}" == "extra-role-policy" && "$*" == *"opensearch-lab-github-actions"* ]]; then
      jq -nc '{AttachedPolicies:[{PolicyName:"unexpected",PolicyArn:"synthetic"}]}'
    else
      jq -nc '{AttachedPolicies:[]}'
    fi
    ;;
  *" iam list-role-policies "*)
    if [[ "$*" == *"opensearch-lab-terraform-admin"* ]]; then
      jq -nc '{PolicyNames:["opensearch-lab-bootstrap-management"]}'
    elif [[ "${FAKE_SCENARIO:-}" == "extra-role-inline-policy" ]]; then
      jq -nc '{PolicyNames:["opensearch-lab-bootstrap-state","unexpected"]}'
    else
      jq -nc '{PolicyNames:["opensearch-lab-bootstrap-state"]}'
    fi
    ;;
  *" iam get-role "*)
    if [[ "$*" == *"opensearch-lab-terraform-admin"* ]]; then
      if [[ "${FAKE_SCENARIO:-}" == "wrong-trust" ]]; then
        jq -nc \
          --arg account_id "${account_id}" \
          '{
            Role: {
              RoleName: "opensearch-lab-terraform-admin",
              AssumeRolePolicyDocument: {},
              PermissionsBoundary: {
                PermissionsBoundaryArn: (
                  "arn:aws:iam::" + $account_id
                  + ":policy/opensearch-lab-terraform-admin-boundary"
                )
              }
            }
          }'
      else
        jq -c \
          --arg account_id "${account_id}" \
          --arg scenario "${FAKE_SCENARIO:-}" '
            def reordered:
              if type == "object" then
                to_entries | reverse | map(.value |= reordered) | from_entries
              elif type == "array" then
                map(reordered) | reverse
              else
                .
              end;
            {
              Role: {
                RoleName: "opensearch-lab-terraform-admin",
                AssumeRolePolicyDocument: (
                  .human_trust
                  | if $scenario == "reordered-policy-documents" then reordered else . end
                ),
                PermissionsBoundary: {
                  PermissionsBoundaryArn: (
                    if $scenario == "wrong-role-boundary"
                    then "arn:aws:iam::" + $account_id + ":policy/unexpected"
                    else .human_boundary_arn
                    end
                  )
                }
              }
            }
          ' \
          "${documents_file}"
      fi
    else
      jq -c --arg scenario "${FAKE_SCENARIO:-}" '
        def reordered:
          if type == "object" then
            to_entries | reverse | map(.value |= reordered) | from_entries
          elif type == "array" then
            map(reordered) | reverse
          else
            .
          end;
        {
          Role: {
            RoleName: "opensearch-lab-github-actions",
            AssumeRolePolicyDocument: (
              .github_trust
              | if $scenario == "reordered-policy-documents" then reordered else . end
            ),
            PermissionsBoundary: {
              PermissionsBoundaryArn: .github_boundary_arn
            }
          }
        }
      ' \
        "${documents_file}"
    fi
    ;;
  *" iam get-open-id-connect-provider "*)
    if [[ "${FAKE_SCENARIO:-}" == "extra-audience" ]]; then
      jq -nc '{Url:"token.actions.githubusercontent.com",ClientIDList:["sts.amazonaws.com","unexpected"]}'
    else
      jq -nc '{Url:"token.actions.githubusercontent.com",ClientIDList:["sts.amazonaws.com"]}'
    fi
    ;;
  *" iam get-policy-version "*)
    if [[ "$*" == *"opensearch-lab-terraform-admin-boundary"* ]]; then
      if [[ "${FAKE_SCENARIO:-}" == "changed-boundary-policy" ]]; then
        jq -c '{PolicyVersion:{Document:(.human_boundary.Statement[0].Sid = "Changed"),VersionId:"v1",IsDefaultVersion:true}}' \
          "${documents_file}"
      elif [[ "${FAKE_SCENARIO:-}" == "reordered-policy-documents" ]]; then
        jq -c '
          def reordered:
            if type == "object" then
              to_entries | reverse | map(.value |= reordered) | from_entries
            elif type == "array" then
              map(reordered) | reverse
            else
              .
            end;
          {PolicyVersion:{Document:(.human_boundary | reordered),VersionId:"v1",IsDefaultVersion:true}}
        ' "${documents_file}"
      else
        jq -c '{PolicyVersion:{Document:.human_boundary,VersionId:"v1",IsDefaultVersion:true}}' \
          "${documents_file}"
      fi
    elif [[ "$*" == *"opensearch-lab-github-actions-boundary"* ]]; then
      if [[ "${FAKE_SCENARIO:-}" == "reordered-policy-documents" ]]; then
        jq -c '
          def reordered:
            if type == "object" then
              to_entries | reverse | map(.value |= reordered) | from_entries
            elif type == "array" then
              map(reordered) | reverse
            else
              .
            end;
          {PolicyVersion:{Document:(.github_boundary | reordered),VersionId:"v1",IsDefaultVersion:true}}
        ' "${documents_file}"
      else
        jq -c '{PolicyVersion:{Document:.github_boundary,VersionId:"v1",IsDefaultVersion:true}}' \
          "${documents_file}"
      fi
    elif [[ "${FAKE_SCENARIO:-}" == "changed-temporary-policy" ]]; then
      jq -c '{PolicyVersion:{Document:(.Statement[0].Sid = "Changed"),VersionId:"v1",IsDefaultVersion:true}}' \
        "${temporary_policy}"
    elif [[ "${FAKE_SCENARIO:-}" == "reordered-policy-documents" ]]; then
      jq -c '
        def reordered:
          if type == "object" then
            to_entries | reverse | map(.value |= reordered) | from_entries
          elif type == "array" then
            map(reordered) | reverse
          else
            .
          end;
        {PolicyVersion:{Document:(. | reordered),VersionId:"v1",IsDefaultVersion:true}}
      ' "${temporary_policy}"
    else
      jq -c '{PolicyVersion:{Document:.,VersionId:"v1",IsDefaultVersion:true}}' \
        "${temporary_policy}"
    fi
    ;;
  *" iam list-entities-for-policy "*)
    if [[ "${FAKE_SCENARIO:-}" == "extra-temporary-policy-entity" ]]; then
      jq -nc '{
        PolicyGroups:[{GroupName:"unexpected"}],
        PolicyRoles:[],
        PolicyUsers:[{UserName:"opensearch-lab-bootstrap"}]
      }'
    else
      jq -nc '{
        PolicyGroups:[],
        PolicyRoles:[],
        PolicyUsers:[{UserName:"opensearch-lab-bootstrap"}]
      }'
    fi
    ;;
  *" iam get-policy "*)
    if [[ "$*" == *"opensearch-lab-temporary-bootstrap"* ]] &&
      [[ "${FAKE_PHASE}" == "after" ]] &&
      [[ "${FAKE_SCENARIO:-}" != "temporary-policy-still-exists" ]]; then
      echo 'An error occurred (NoSuchEntity) when calling the GetPolicy operation' >&2
      exit 254
    fi
    jq -nc '{Policy:{DefaultVersionId:"v1"}}'
    ;;
  *)
    exit 1
    ;;
esac
EOF

chmod 700 "${fixture_root}/bin/aws" "${fixture_root}/bin/terraform"
AWS_ACCOUNT_ID="${account_id}" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" >/dev/null

run_verification() {
  phase="$1"
  scenario="${2:-}"
  PATH="${fixture_root}/bin:${PATH}" \
    AWS_PROFILE=opensearch-lab-admin \
    FAKE_ACCOUNT_ID="${account_id}" \
    FAKE_FIXTURE_ROOT="${fixture_root}" \
    FAKE_PHASE="${phase}" \
    FAKE_SCENARIO="${scenario}" \
    "${fixture_root}/infra/bootstrap/scripts/verify-bootstrap-access.sh" \
    "--${phase}-removal"
}

run_verification before >/dev/null
run_verification after >/dev/null
run_verification before reordered-policy-documents >/dev/null
printf 'positive case: reordered-policy-documents\n'

expected_verification_diagnostic() {
  case "$1" in
    access-key)
      printf '%s\n' 'The bootstrap user has an access key.'
      ;;
    backend-endpoint-credential-override)
      printf '%s\n' 'The s3-migration backend does not match its exact reviewed contract.'
      ;;
    changed-bucket-policy)
      printf '%s\n' 'The live state bucket policy differs from Terraform state.'
      ;;
    changed-boundary-policy)
      printf '%s\n' 'A live permissions boundary differs from its resolved private document.'
      ;;
    changed-temporary-policy)
      printf '%s\n' 'The attached temporary policy differs from the resolved private policy.'
      ;;
    extra-audience)
      printf '%s\n' 'The GitHub OIDC provider URL or audience allow-list failed.'
      ;;
    extra-role-policy)
      printf '%s\n' 'A bootstrap role has an unexpected attached policy.'
      ;;
    extra-role-inline-policy)
      printf '%s\n' 'A bootstrap role inline-policy allow-list failed.'
      ;;
    extra-temporary-policy-entity)
      printf '%s\n' 'The temporary policy is attached to an unexpected identity.'
      ;;
    extra-user-inline)
      printf '%s\n' 'The bootstrap user inline-policy allow-list failed.'
      ;;
    extra-user-policy)
      printf '%s\n' 'The bootstrap user attached-policy allow-list failed before removal.'
      ;;
    group)
      printf '%s\n' 'The bootstrap user has unexpected group membership.'
      ;;
    missing-mfa)
      printf '%s\n' 'The bootstrap user does not have a live MFA device.'
      ;;
    mutated-tracked-policy-template)
      printf '%s\n' 'A tracked bootstrap policy template differs from its reviewed contract.'
      ;;
    stale-resolved-boundary)
      printf '%s\n' 'A resolved private permissions boundary is stale or differs from its tracked template.'
      ;;
    stale-resolved-temporary-policy)
      printf '%s\n' 'The resolved private temporary policy is stale, expired or differs from its tracked template.'
      ;;
    changed-role-inline-policy)
      printf '%s\n' 'A bootstrap role inline policy differs from Terraform state.'
      ;;
    temporary-policy-still-exists)
      printf '%s\n' 'The temporary policy still exists after removal.'
      ;;
    user-boundary)
      printf '%s\n' 'The bootstrap user has an unexpected permissions boundary.'
      ;;
    wrong-caller-role)
      printf '%s\n' 'Verification must run through the Terraform administration role.'
      ;;
    wrong-role-boundary)
      printf '%s\n' 'A bootstrap role permissions boundary differs from Terraform state.'
      ;;
    wrong-trust)
      printf '%s\n' 'A bootstrap role trust policy differs from Terraform state.'
      ;;
    *)
      echo "No expected verifier diagnostic is defined for scenario: $1" >&2
      return 1
      ;;
  esac
}

expect_verification_failure() {
  phase="$1"
  scenario="$2"
  expected_diagnostic="$(expected_verification_diagnostic "${scenario}")"
  verification_output=""

  if verification_output="$(run_verification "${phase}" "${scenario}" 2>&1)"; then
    echo "Access verification accepted scenario: ${scenario}" >&2
    exit 1
  fi

  if [[ "${verification_output}" != "${expected_diagnostic}" ]]; then
    printf 'Access verification failed with an unexpected diagnostic for scenario %s.\n' \
      "${scenario}" >&2
    printf 'Expected: %s\n' "${expected_diagnostic}" >&2
    printf 'Actual: %s\n' "${verification_output:-<no output>}" >&2
    exit 1
  fi

  negative_case_count=$((negative_case_count + 1))
  printf 'negative case: %s\n' "${scenario}"
}

backend_file="${fixture_root}/infra/bootstrap/backend.tf"
backend_recovery="${fixture_root}/backend.tf.reviewed"
backend_mutation="${fixture_root}/backend.tf.mutated"
cp "${backend_file}" "${backend_recovery}"
awk '
  { print }
  /use_lockfile = true/ {
    print "    access_key = \"synthetic\""
    print "    endpoints  = { s3 = \"http://127.0.0.1:4566\" }"
  }
' "${backend_file}" >"${backend_mutation}"
mv "${backend_mutation}" "${backend_file}"
grep -Fq 'access_key = "synthetic"' "${backend_file}"
grep -Fq 'endpoints  = { s3 = "http://127.0.0.1:4566" }' "${backend_file}"
expect_verification_failure before backend-endpoint-credential-override
mv "${backend_recovery}" "${backend_file}"

github_boundary_template="${fixture_root}/infra/bootstrap/policies/github-actions-boundary.template.json"
github_boundary_template_recovery="${test_root}/github-actions-boundary.reviewed.json"
github_boundary_template_mutation="${test_root}/github-actions-boundary.mutated.json"
cp "${github_boundary_template}" "${github_boundary_template_recovery}"
jq '(.Statement[] | select(.Sid == "ReadAndWriteTerraformState") | .Action) += ["s3:GetObjectVersion"]' \
  "${github_boundary_template}" >"${github_boundary_template_mutation}"
mv "${github_boundary_template_mutation}" "${github_boundary_template}"
jq -e 'any(.Statement[]; .Sid == "ReadAndWriteTerraformState" and (.Action | index("s3:GetObjectVersion") != null))' \
  "${github_boundary_template}" >/dev/null
expect_verification_failure before mutated-tracked-policy-template
mv "${github_boundary_template_recovery}" "${github_boundary_template}"

human_boundary_file="${fixture_root}/.private/terraform-bootstrap/terraform-admin-boundary.json"
human_boundary_recovery="${test_root}/terraform-admin-boundary.reviewed.json"
human_boundary_mutation="${test_root}/terraform-admin-boundary.mutated.json"
cp "${human_boundary_file}" "${human_boundary_recovery}"
jq '(.Statement[] | select(.Sid == "ManageStateBucketControls") | .Action) += ["s3:DeleteBucket"]' \
  "${human_boundary_file}" >"${human_boundary_mutation}"
mv "${human_boundary_mutation}" "${human_boundary_file}"
chmod 600 "${human_boundary_file}"
jq -e 'any(.Statement[]; .Sid == "ManageStateBucketControls" and (.Action | index("s3:DeleteBucket") != null))' \
  "${human_boundary_file}" >/dev/null
expect_verification_failure before stale-resolved-boundary
mv "${human_boundary_recovery}" "${human_boundary_file}"

temporary_policy_file="${fixture_root}/.private/terraform-bootstrap/temporary-bootstrap-policy.json"
temporary_policy_recovery="${test_root}/temporary-bootstrap-policy.reviewed.json"
temporary_policy_mutation="${test_root}/temporary-bootstrap-policy.mutated.json"
cp "${temporary_policy_file}" "${temporary_policy_recovery}"
jq '(.Statement[] | select(.Sid == "ReadExactBootstrapUser") | .Action) = ["iam:GetUser", "iam:GetUserPolicy"]' \
  "${temporary_policy_file}" >"${temporary_policy_mutation}"
mv "${temporary_policy_mutation}" "${temporary_policy_file}"
chmod 600 "${temporary_policy_file}"
jq -e 'any(.Statement[]; .Sid == "ReadExactBootstrapUser" and (.Action | index("iam:GetUserPolicy") != null))' \
  "${temporary_policy_file}" >/dev/null
expect_verification_failure before stale-resolved-temporary-policy
mv "${temporary_policy_recovery}" "${temporary_policy_file}"

for failing_scenario in \
  access-key \
  changed-bucket-policy \
  changed-role-inline-policy \
  changed-temporary-policy \
  changed-boundary-policy \
  extra-audience \
  extra-role-policy \
  extra-role-inline-policy \
  extra-temporary-policy-entity \
  extra-user-inline \
  extra-user-policy \
  group \
  missing-mfa \
  user-boundary \
  wrong-caller-role \
  wrong-role-boundary \
  wrong-trust; do
  expect_verification_failure before "${failing_scenario}"
done

expect_verification_failure after temporary-policy-still-exists

printf 'Bootstrap access allow-list safeguards passed (%d negative cases).\n' \
  "${negative_case_count}"
