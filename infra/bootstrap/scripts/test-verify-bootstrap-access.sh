#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
account_id="$(printf '%06d%06d' 123 456)"
state_bucket_name="opensearch-lab-tfstate-ocdaithi-1346323330-eu-west-1"
terraform_admin_role_arn="arn:aws:iam::${account_id}:role/opensearch-lab-terraform-admin"
fixture_root="${test_root}/fixture"
call_trace_file="${test_root}/aws-calls.log"
negative_case_count=0
: >"${call_trace_file}"

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

if ! jq -e --arg account_id "${account_id}" '
  def statement($sid):
    [.Statement[] | select(.Sid == $sid)]
    | if length == 1 then .[0] else null end;
  . as $policy
  | ($policy.Statement | length) == 11
    and all($policy.Statement[]; .Sid != "ListExactTerraformStateKeys")
    and ($policy | statement("ReadDefaultBillingViewData") |
      .Action == "billing:GetBillingViewData"
      and .Resource
        == ("arn:aws:billing::" + $account_id + ":billingview/primary"))
' "${fixture_root}/.private/terraform-bootstrap/terraform-admin-boundary.json" \
  >/dev/null; then
  echo 'The verifier fixture human boundary lacks its reviewed static contract.' >&2
  exit 1
fi

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
    human_inline: $human_boundary[0],
    human_max_session_duration: 3600,
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
    github_inline: $github_boundary[0],
    github_max_session_duration: 3600,
    state_bucket_name: $state_bucket_name,
    state_versioning: [{status: "Enabled", mfa_delete: ""}],
    state_encryption: [{
      apply_server_side_encryption_by_default: [{
        kms_master_key_id: "",
        sse_algorithm: "AES256"
      }],
      bucket_key_enabled: false
    }],
    state_public_access_block: {
      block_public_acls: true,
      block_public_policy: true,
      ignore_public_acls: true,
      restrict_public_buckets: true
    },
    state_ownership: [{object_ownership: "BucketOwnerEnforced"}],
    state_lifecycle: [{
      id: "retain-recent-noncurrent-state",
      status: "Enabled",
      filter: [{prefix: "", and: [], tag: []}],
      noncurrent_version_expiration: [{
        newer_noncurrent_versions: 10,
        noncurrent_days: 90
      }],
      expiration: [],
      transition: [],
      noncurrent_version_transition: []
    }],
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
    ),
    budget: {
      account_id: $account_id,
      arn: (
        "arn:aws:budgets::" + $account_id
        + ":budget/opensearch-lab-monthly-cost"
      ),
      name: "opensearch-lab-monthly-cost",
      budget_type: "COST",
      limit_amount: "50",
      limit_unit: "USD",
      time_unit: "MONTHLY",
      metrics: ["UnblendedCost"],
      filter_expression: [{
        not: [{
          dimensions: [{
            key: "RECORD_TYPE",
            values: ["Credit", "Refund"],
            match_options: []
          }]
        }]
      }],
      notification: (([10, 25, 40, 50] | map({
        comparison_operator: "GREATER_THAN",
        threshold: .,
        threshold_type: "ABSOLUTE_VALUE",
        notification_type: "ACTUAL",
        subscriber_email_addresses: ["alerts@example.com"],
        subscriber_sns_topic_arns: []
      })) + [{
        comparison_operator: "GREATER_THAN",
        threshold: 50,
        threshold_type: "ABSOLUTE_VALUE",
        notification_type: "FORECASTED",
        subscriber_email_addresses: ["alerts@example.com"],
        subscriber_sns_topic_arns: []
      }])
    }
  }
' >"${fixture_root}/actual-documents.json"

cat >"${fixture_root}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" != *" show -json"* ]]; then
  exit 1
fi

jq -nc --slurpfile documents "${FAKE_FIXTURE_ROOT}/actual-documents.json" '
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
                permissions_boundary: $documents.human_boundary_arn,
                max_session_duration: $documents.human_max_session_duration
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
                permissions_boundary: $documents.github_boundary_arn,
                max_session_duration: $documents.github_max_session_duration
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
              address: "aws_s3_bucket_versioning.state",
              values: {versioning_configuration: $documents.state_versioning}
            },
            {
              address: "aws_s3_bucket_server_side_encryption_configuration.state",
              values: {rule: $documents.state_encryption}
            },
            {
              address: "aws_s3_bucket_public_access_block.state",
              values: $documents.state_public_access_block
            },
            {
              address: "aws_s3_bucket_ownership_controls.state",
              values: {rule: $documents.state_ownership}
            },
            {
              address: "aws_s3_bucket_lifecycle_configuration.state",
              values: {rule: $documents.state_lifecycle}
            },
            {
              address: "aws_s3_bucket_policy.state",
              values: {policy: ($documents.state_bucket_policy | tojson)}
            },
            {
              address: "aws_budgets_budget.account_cost",
              values: $documents.budget
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

documents_file="${FAKE_FIXTURE_ROOT}/actual-documents.json"
account_id="${FAKE_ACCOUNT_ID}"
temporary_policy="${FAKE_FIXTURE_ROOT}/.private/terraform-bootstrap/temporary-bootstrap-policy.json"
printf '%s|%s\n' "${FAKE_SCENARIO:-default}" "$*" >>"${FAKE_CALL_TRACE}"

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
  *" s3api get-bucket-versioning "*)
    if [[ "${FAKE_SCENARIO:-}" == "suspended-bucket-versioning" ]]; then
      jq -nc '{Status:"Suspended"}'
    else
      jq -nc '{Status:"Enabled"}'
    fi
    ;;
  *" s3api get-bucket-encryption "*)
    if [[ "${FAKE_SCENARIO:-}" == "kms-bucket-encryption" ]]; then
      jq -nc '{ServerSideEncryptionConfiguration:{Rules:[{
        ApplyServerSideEncryptionByDefault:{
          SSEAlgorithm:"aws:kms",
          KMSMasterKeyID:"synthetic"
        },
        BucketKeyEnabled:true
      }]}}'
    else
      jq -nc '{ServerSideEncryptionConfiguration:{Rules:[{
        ApplyServerSideEncryptionByDefault:{SSEAlgorithm:"AES256"},
        BucketKeyEnabled:false
      }]}}'
    fi
    ;;
  *" s3api get-public-access-block "*)
    jq -nc --arg scenario "${FAKE_SCENARIO:-}" '{
      PublicAccessBlockConfiguration: {
        BlockPublicAcls: true,
        BlockPublicPolicy: ($scenario != "disabled-public-access-block"),
        IgnorePublicAcls: true,
        RestrictPublicBuckets: true
      }
    }'
    ;;
  *" s3api get-bucket-ownership-controls "*)
    if [[ "${FAKE_SCENARIO:-}" == "object-writer-ownership" ]]; then
      jq -nc '{OwnershipControls:{Rules:[{ObjectOwnership:"ObjectWriter"}]}}'
    else
      jq -nc '{OwnershipControls:{Rules:[{ObjectOwnership:"BucketOwnerEnforced"}]}}'
    fi
    ;;
  *" s3api get-bucket-lifecycle-configuration "*)
    jq -nc --arg scenario "${FAKE_SCENARIO:-}" '{
      Rules: [{
        ID: "retain-recent-noncurrent-state",
        Status: "Enabled",
        Filter: {Prefix: ""},
        NoncurrentVersionExpiration: {
          NoncurrentDays: (if $scenario == "changed-bucket-lifecycle" then 30 else 90 end),
          NewerNoncurrentVersions: 10
        }
      }]
    }'
    ;;
  *" budgets describe-notifications-for-budget "*)
    jq -nc --arg scenario "${FAKE_SCENARIO:-}" '
      ([10, 25, 40, 50] | map({
        NotificationType: "ACTUAL",
        ComparisonOperator: "GREATER_THAN",
        Threshold: .,
        ThresholdType: "ABSOLUTE_VALUE"
      })) + [{
        NotificationType: "FORECASTED",
        ComparisonOperator: "GREATER_THAN",
        Threshold: (if $scenario == "changed-budget-notification" then 40 else 50 end),
        ThresholdType: "ABSOLUTE_VALUE"
      }]
      | {Notifications: .}
    '
    ;;
  *" budgets describe-subscribers-for-notification "*)
    if [[ "${FAKE_SCENARIO:-}" == "changed-budget-subscriber" ]]; then
      jq -nc '{Subscribers:[{SubscriptionType:"SNS",Address:"synthetic"}]}'
    else
      jq -c '{Subscribers:[{
        SubscriptionType:"EMAIL",
        Address:.budget.notification[0].subscriber_email_addresses[0]
      }]}' "${documents_file}"
    fi
    ;;
  *" budgets describe-budget "*)
    if [[ "$*" != *" --show-filter-expression"* ]]; then
      exit 1
    fi
    jq -c --arg scenario "${FAKE_SCENARIO:-}" '{
      Budget: {
        BudgetName: (
          if $scenario == "wrong-budget-identity"
          then "unexpected"
          else .budget.name
          end
        ),
        BudgetLimit: {
          Amount: (if $scenario == "wrong-budget-amount" then "75" else .budget.limit_amount end),
          Unit: .budget.limit_unit
        },
        BudgetType: .budget.budget_type,
        TimeUnit: .budget.time_unit,
        Metrics: .budget.metrics,
        CostTypes: (
          if $scenario == "wrong-budget-cost-types"
          then {IncludeCredit: false}
          else null
          end
        ),
        FilterExpression: {
          Not: {
            Dimensions: {
              Key: "RECORD_TYPE",
              Values: (
                if $scenario == "wrong-budget-filter"
                then ["Credit"]
                else ["Credit", "Refund"]
                end
              ),
              MatchOptions: ["EQUALS"]
            }
          }
        }
      }
    }' "${documents_file}"
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
    if [[ "${FAKE_SCENARIO:-}" == "iam-error-redaction" ]]; then
      printf 'Access denied for arn:aws:iam::%s:user/private-identifier\n' "${account_id}" >&2
      exit 254
    elif [[ "${FAKE_SCENARIO:-}" == "iam-unrelated-not-found-error" ]]; then
      echo 'The selected local configuration was not found.' >&2
      exit 254
    elif [[ "${FAKE_SCENARIO:-}" == "iam-propagation-delay" ]] &&
      (($(grep -Fc 'iam-propagation-delay|--profile opensearch-lab-admin iam get-user' "${FAKE_CALL_TRACE}") < 3)); then
      echo 'An error occurred (NoSuchEntity) when calling the GetUser operation' >&2
      exit 254
    elif [[ "${FAKE_SCENARIO:-}" == "user-boundary" ]]; then
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
              MaxSessionDuration: 3600,
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
                MaxSessionDuration: (
                  if $scenario == "wrong-role-session-duration"
                  then 43200
                  else .human_max_session_duration
                  end
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
            MaxSessionDuration: .github_max_session_duration,
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
      jq -c '{Url:.oidc_url,ClientIDList:.oidc_audiences}' "${documents_file}"
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
      [[ "${FAKE_PHASE}" == "after" ]]; then
      if [[ "${FAKE_SCENARIO:-}" == "temporary-policy-deletion-delay" ]]; then
        deletion_attempts="$(awk -F '|' '
          $1 == "temporary-policy-deletion-delay" &&
            $2 ~ /iam get-policy --policy-arn/ &&
            $2 ~ /opensearch-lab-temporary-bootstrap/ { count++ }
          END { print count + 0 }
        ' "${FAKE_CALL_TRACE}")"
        if ((deletion_attempts < 3)); then
          jq -nc '{Policy:{DefaultVersionId:"v1"}}'
          exit 0
        fi
      fi
      if [[ "${FAKE_SCENARIO:-}" != "temporary-policy-still-exists" ]]; then
        echo 'An error occurred (NoSuchEntity) when calling the GetPolicy operation' >&2
        exit 254
      fi
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

if ! jq -e --arg account_id "${account_id}" '
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
        == ("arn:aws:iam::" + $account_id + ":user/opensearch-lab-bootstrap")
      and .Condition.ArnLike["aws:SignInSessionArn"]
        == ("arn:aws:signin:*:" + $account_id + ":session/*")
      and (.Condition.DateLessThan["aws:CurrentTime"] |
        type == "string"
        and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    )
    and ($policy | statement("ReadDefaultBillingViewData") |
      .Action == "billing:GetBillingViewData"
      and .Resource
        == ("arn:aws:billing::" + $account_id + ":billingview/primary"))
' "${fixture_root}/.private/terraform-bootstrap/temporary-bootstrap-policy.json" \
  >/dev/null; then
  echo 'The verifier fixture temporary policy lacks its reviewed static contract.' >&2
  exit 1
fi

run_verification() {
  phase="$1"
  scenario="${2:-}"
  PATH="${fixture_root}/bin:${PATH}" \
    AWS_PROFILE=opensearch-lab-admin \
    BUDGET_NOTIFICATION_EMAIL=alerts@example.com \
    BOOTSTRAP_VERIFY_IAM_RETRY_DELAY_SECONDS=0 \
    FAKE_ACCOUNT_ID="${account_id}" \
    FAKE_CALL_TRACE="${call_trace_file}" \
    FAKE_FIXTURE_ROOT="${fixture_root}" \
    FAKE_PHASE="${phase}" \
    FAKE_SCENARIO="${scenario}" \
    "${fixture_root}/infra/bootstrap/scripts/verify-bootstrap-access.sh" \
    "--${phase}-removal"
}

run_verification before >/dev/null
run_verification after >/dev/null
if ! grep -Fq 'budgets describe-budget' "${call_trace_file}" ||
  ! grep -F 'budgets describe-budget' "${call_trace_file}" |
    grep -Fq -- '--show-filter-expression'; then
  echo 'The budget read-back did not request its filter expression.' >&2
  exit 1
fi
printf 'positive case: explicit-budget-filter-readback\n'
run_verification before reordered-policy-documents >/dev/null
printf 'positive case: reordered-policy-documents\n'
run_verification before iam-propagation-delay >/dev/null
if (($(grep -Fc 'iam-propagation-delay|--profile opensearch-lab-admin iam get-user' \
  "${call_trace_file}") != 3)); then
  echo 'The bounded IAM propagation retry case did not make exactly three attempts.' >&2
  exit 1
fi
printf 'positive case: bounded-iam-propagation-retry\n'
run_verification after temporary-policy-deletion-delay >/dev/null
deletion_attempts="$(awk -F '|' '
  $1 == "temporary-policy-deletion-delay" &&
    $2 ~ /iam get-policy --policy-arn/ &&
    $2 ~ /opensearch-lab-temporary-bootstrap/ { count++ }
  END { print count + 0 }
' "${call_trace_file}")"
if ((deletion_attempts != 3)); then
  echo 'The bounded IAM deletion propagation case did not make exactly three attempts.' >&2
  exit 1
fi
printf 'positive case: bounded-iam-deletion-propagation-retry\n'

expected_verification_diagnostic() {
  case "$1" in
    access-key)
      printf '%s\n' 'The bootstrap user has an access key.'
      ;;
    backend-endpoint-credential-override)
      printf '%s\n' 'The s3-migration backend does not match its exact reviewed contract.'
      ;;
    changed-bucket-policy)
      printf '%s\n' 'The live state bucket policy differs from the independent reviewed contract.'
      ;;
    changed-boundary-policy)
      printf '%s\n' 'A live permissions boundary differs from the independent reviewed contract.'
      ;;
    changed-temporary-policy)
      printf '%s\n' 'The attached temporary policy differs from the independent reviewed contract.'
      ;;
    changed-budget-notification)
      printf '%s\n' 'The live budget notifications differ from the reviewed contract.'
      ;;
    changed-budget-subscriber)
      printf '%s\n' 'A live budget notification subscriber differs from the independent reviewed contract.'
      ;;
    changed-bucket-lifecycle)
      printf '%s\n' 'The live state bucket lifecycle configuration differs from the reviewed contract.'
      ;;
    disabled-public-access-block)
      printf '%s\n' 'The live state bucket public-access block differs from the reviewed contract.'
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
    iam-error-redaction | iam-unrelated-not-found-error)
      printf '%s\n' 'AWS access allow-list verification could not complete.'
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
    stale-resolved-temporary-billing | stale-resolved-temporary-expiry | \
      stale-resolved-temporary-principal | stale-resolved-temporary-sign-in)
      printf '%s\n' 'The resolved private temporary policy is stale, expired or differs from its tracked template.'
      ;;
    changed-role-inline-policy)
      printf '%s\n' 'A bootstrap role inline policy differs from the independent reviewed contract.'
      ;;
    kms-bucket-encryption)
      printf '%s\n' 'The live state bucket encryption differs from the reviewed AES256 contract.'
      ;;
    object-writer-ownership)
      printf '%s\n' 'The live state bucket ownership controls differ from the reviewed contract.'
      ;;
    paired-additional-administration-permission | paired-broadened-human-trust | \
      paired-public-bucket-grant | paired-state-object-deletion | paired-wildcard-github-subject)
      printf '%s\n' 'Terraform state policy semantics differ from the independent reviewed contract.'
      ;;
    paired-additional-github-audience | paired-budget-recipient | paired-missing-boundary | paired-replaced-boundary)
      printf '%s\n' 'Terraform state resource settings differ from the independent reviewed contract.'
      ;;
    state-extra-lifecycle-filter | state-missing-budget-account)
      printf '%s\n' 'Terraform state resource settings differ from the independent reviewed contract.'
      ;;
    suspended-bucket-versioning)
      printf '%s\n' 'The live state bucket versioning differs from the reviewed contract.'
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
      printf '%s\n' 'A bootstrap role boundary or maximum session duration differs from the reviewed contract.'
      ;;
    wrong-role-session-duration)
      printf '%s\n' 'A bootstrap role boundary or maximum session duration differs from the reviewed contract.'
      ;;
    wrong-trust)
      printf '%s\n' 'A bootstrap role trust policy differs from the independent reviewed contract.'
      ;;
    wrong-budget-amount | wrong-budget-cost-types | wrong-budget-filter | wrong-budget-identity)
      printf '%s\n' 'The live budget identity, amount or filters differ from the reviewed contract.'
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
jq --arg account_id "${account_id}" '
  (.Statement[] | select(.Sid == "ReadDefaultBillingViewData") | .Resource)
    = ("arn:aws:billing::" + $account_id + ":billingview/custom")
' \
  "${human_boundary_file}" >"${human_boundary_mutation}"
mv "${human_boundary_mutation}" "${human_boundary_file}"
chmod 600 "${human_boundary_file}"
jq -e 'any(.Statement[];
  .Sid == "ReadDefaultBillingViewData"
  and (.Resource | endswith(":billingview/custom")))' \
  "${human_boundary_file}" >/dev/null
expect_verification_failure before stale-resolved-boundary
mv "${human_boundary_recovery}" "${human_boundary_file}"

temporary_policy_file="${fixture_root}/.private/terraform-bootstrap/temporary-bootstrap-policy.json"
temporary_policy_recovery="${test_root}/temporary-bootstrap-policy.reviewed.json"
temporary_policy_mutation="${test_root}/temporary-bootstrap-policy.mutated.json"
cp "${temporary_policy_file}" "${temporary_policy_recovery}"
jq 'del(.Statement[0].Condition.ArnEquals["aws:PrincipalArn"])' \
  "${temporary_policy_file}" >"${temporary_policy_mutation}"
mv "${temporary_policy_mutation}" "${temporary_policy_file}"
chmod 600 "${temporary_policy_file}"
jq -e '.Statement[0].Condition.ArnEquals | has("aws:PrincipalArn") | not' \
  "${temporary_policy_file}" >/dev/null
expect_verification_failure before stale-resolved-temporary-principal
cp "${temporary_policy_recovery}" "${temporary_policy_file}"

jq 'del(.Statement[0].Condition.ArnLike["aws:SignInSessionArn"])' \
  "${temporary_policy_file}" >"${temporary_policy_mutation}"
mv "${temporary_policy_mutation}" "${temporary_policy_file}"
chmod 600 "${temporary_policy_file}"
jq -e '.Statement[0].Condition.ArnLike | has("aws:SignInSessionArn") | not' \
  "${temporary_policy_file}" >/dev/null
expect_verification_failure before stale-resolved-temporary-sign-in
cp "${temporary_policy_recovery}" "${temporary_policy_file}"

jq 'del(.Statement[0].Condition.DateLessThan["aws:CurrentTime"])' \
  "${temporary_policy_file}" >"${temporary_policy_mutation}"
mv "${temporary_policy_mutation}" "${temporary_policy_file}"
chmod 600 "${temporary_policy_file}"
jq -e '.Statement[0].Condition.DateLessThan | has("aws:CurrentTime") | not' \
  "${temporary_policy_file}" >/dev/null
expect_verification_failure before stale-resolved-temporary-expiry
cp "${temporary_policy_recovery}" "${temporary_policy_file}"

jq '(.Statement[] | select(.Sid == "ReadDefaultBillingViewData") | .Resource) = "*"' \
  "${temporary_policy_file}" >"${temporary_policy_mutation}"
mv "${temporary_policy_mutation}" "${temporary_policy_file}"
chmod 600 "${temporary_policy_file}"
jq -e 'any(.Statement[];
  .Sid == "ReadDefaultBillingViewData" and .Resource == "*")' \
  "${temporary_policy_file}" >/dev/null
expect_verification_failure before stale-resolved-temporary-billing
mv "${temporary_policy_recovery}" "${temporary_policy_file}"

render_fake_terraform_state() {
  PATH="${fixture_root}/bin:${PATH}" \
    FAKE_FIXTURE_ROOT="${fixture_root}" \
    "${fixture_root}/bin/terraform" -chdir="${fixture_root}/infra/bootstrap" show -json
}

run_fake_aws() {
  local scenario="$1"
  shift

  PATH="${fixture_root}/bin:${PATH}" \
    FAKE_ACCOUNT_ID="${account_id}" \
    FAKE_CALL_TRACE="${call_trace_file}" \
    FAKE_FIXTURE_ROOT="${fixture_root}" \
    FAKE_PHASE=before \
    FAKE_SCENARIO="${scenario}" \
    "${fixture_root}/bin/aws" --profile opensearch-lab-admin "$@" --output json
}

run_paired_state_and_aws_mutation() {
  local case_name="$1"
  local documents_file="${fixture_root}/actual-documents.json"
  local live_file="${test_root}/${case_name}.live.json"
  local reviewed_file="${test_root}/${case_name}.reviewed.json"
  local state_file="${test_root}/${case_name}.state.json"
  local mutated_file="${test_root}/${case_name}.mutated.json"

  cp "${documents_file}" "${reviewed_file}"
  case "${case_name}" in
    paired-wildcard-github-subject)
      jq '.github_trust.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] = "repo:*"' \
        "${documents_file}" >"${mutated_file}"
      ;;
    paired-additional-github-audience)
      jq '.oidc_audiences += ["unexpected.example"]' \
        "${documents_file}" >"${mutated_file}"
      ;;
    paired-broadened-human-trust)
      jq '.human_trust.Statement[0].Principal.AWS = "*"' \
        "${documents_file}" >"${mutated_file}"
      ;;
    paired-additional-administration-permission)
      jq '(.human_inline.Statement[] | select(.Sid == "AuditExactBootstrapUser") | .Action) += ["iam:DeleteUser"]' \
        "${documents_file}" >"${mutated_file}"
      ;;
    paired-state-object-deletion)
      jq '(.github_inline.Statement[] | select(.Sid == "ReadAndWriteTerraformState") | .Action) += ["s3:DeleteObject"]' \
        "${documents_file}" >"${mutated_file}"
      ;;
    paired-public-bucket-grant)
      jq '.state_bucket_policy.Statement += [{
        Sid: "PublicRead",
        Effect: "Allow",
        Principal: "*",
        Action: "s3:GetObject",
        Resource: ("arn:aws:s3:::" + .state_bucket_name + "/*")
      }]' "${documents_file}" >"${mutated_file}"
      ;;
    paired-missing-boundary)
      jq '.human_boundary_arn = null' "${documents_file}" >"${mutated_file}"
      ;;
    paired-replaced-boundary)
      jq --arg account_id "${account_id}" \
        '.github_boundary_arn = ("arn:aws:iam::" + $account_id + ":policy/unexpected")' \
        "${documents_file}" >"${mutated_file}"
      ;;
    paired-budget-recipient)
      jq '(.budget.notification[].subscriber_email_addresses) = ["unsafe@example.com"]' \
        "${documents_file}" >"${mutated_file}"
      ;;
    *)
      echo "No paired mutation is defined for case: ${case_name}" >&2
      exit 1
      ;;
  esac
  mv "${mutated_file}" "${documents_file}"
  render_fake_terraform_state >"${state_file}"

  case "${case_name}" in
    paired-wildcard-github-subject)
      run_fake_aws "${case_name}" iam get-role \
        --role-name opensearch-lab-github-actions >"${live_file}"
      jq -e '
        [.values.root_module.resources[] | select(.address == "aws_iam_role.github_actions")][0]
        | (.values.assume_role_policy | fromjson)
        | .Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:*"
      ' "${state_file}" >/dev/null
      jq -e '.Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:*"' \
        "${live_file}" >/dev/null
      ;;
    paired-additional-github-audience)
      run_fake_aws "${case_name}" iam get-open-id-connect-provider \
        --open-id-connect-provider-arn synthetic >"${live_file}"
      jq -e '
        [.values.root_module.resources[] | select(.address == "aws_iam_openid_connect_provider.github")][0]
        | .values.client_id_list == ["sts.amazonaws.com", "unexpected.example"]
      ' "${state_file}" >/dev/null
      jq -e '.ClientIDList == ["sts.amazonaws.com", "unexpected.example"]' \
        "${live_file}" >/dev/null
      ;;
    paired-broadened-human-trust)
      run_fake_aws "${case_name}" iam get-role \
        --role-name opensearch-lab-terraform-admin >"${live_file}"
      jq -e '
        [.values.root_module.resources[] | select(.address == "aws_iam_role.terraform_admin")][0]
        | (.values.assume_role_policy | fromjson)
        | .Statement[0].Principal.AWS == "*"
      ' "${state_file}" >/dev/null
      jq -e '.Role.AssumeRolePolicyDocument.Statement[0].Principal.AWS == "*"' \
        "${live_file}" >/dev/null
      ;;
    paired-additional-administration-permission)
      run_fake_aws "${case_name}" iam get-role-policy \
        --role-name opensearch-lab-terraform-admin \
        --policy-name opensearch-lab-bootstrap-management >"${live_file}"
      jq -e '
        [.values.root_module.resources[] | select(.address == "aws_iam_role_policy.terraform_admin")][0]
        | (.values.policy | fromjson)
        | any(.Statement[];
          .Sid == "AuditExactBootstrapUser" and (.Action | index("iam:DeleteUser") != null))
      ' "${state_file}" >/dev/null
      jq -e 'any(.PolicyDocument.Statement[];
        .Sid == "AuditExactBootstrapUser" and (.Action | index("iam:DeleteUser") != null))' \
        "${live_file}" >/dev/null
      ;;
    paired-state-object-deletion)
      run_fake_aws "${case_name}" iam get-role-policy \
        --role-name opensearch-lab-github-actions \
        --policy-name opensearch-lab-bootstrap-state >"${live_file}"
      jq -e '
        [.values.root_module.resources[] | select(.address == "aws_iam_role_policy.github_actions_state")][0]
        | (.values.policy | fromjson)
        | any(.Statement[];
          .Sid == "ReadAndWriteTerraformState" and (.Action | index("s3:DeleteObject") != null))
      ' "${state_file}" >/dev/null
      jq -e 'any(.PolicyDocument.Statement[];
        .Sid == "ReadAndWriteTerraformState" and (.Action | index("s3:DeleteObject") != null))' \
        "${live_file}" >/dev/null
      ;;
    paired-public-bucket-grant)
      run_fake_aws "${case_name}" s3api get-bucket-policy \
        --bucket "${state_bucket_name}" >"${live_file}"
      jq -e '
        [.values.root_module.resources[] | select(.address == "aws_s3_bucket_policy.state")][0]
        | (.values.policy | fromjson)
        | any(.Statement[];
          .Effect == "Allow" and .Principal == "*" and .Action == "s3:GetObject")
      ' "${state_file}" >/dev/null
      jq -e '(.Policy | fromjson) | any(.Statement[];
        .Effect == "Allow" and .Principal == "*" and .Action == "s3:GetObject")' \
        "${live_file}" >/dev/null
      ;;
    paired-missing-boundary)
      run_fake_aws "${case_name}" iam get-role \
        --role-name opensearch-lab-terraform-admin >"${live_file}"
      jq -e '
        [.values.root_module.resources[] | select(.address == "aws_iam_role.terraform_admin")][0]
        | .values.permissions_boundary == null
      ' "${state_file}" >/dev/null
      jq -e '.Role.PermissionsBoundary.PermissionsBoundaryArn == null' \
        "${live_file}" >/dev/null
      ;;
    paired-replaced-boundary)
      run_fake_aws "${case_name}" iam get-role \
        --role-name opensearch-lab-github-actions >"${live_file}"
      jq -e '
        [.values.root_module.resources[] | select(.address == "aws_iam_role.github_actions")][0]
        | .values.permissions_boundary | endswith(":policy/unexpected")
      ' "${state_file}" >/dev/null
      jq -e '.Role.PermissionsBoundary.PermissionsBoundaryArn | endswith(":policy/unexpected")' \
        "${live_file}" >/dev/null
      ;;
    paired-budget-recipient)
      run_fake_aws "${case_name}" budgets describe-subscribers-for-notification \
        --account-id "${account_id}" \
        --budget-name opensearch-lab-monthly-cost \
        --notification synthetic >"${live_file}"
      jq -e '
        [.values.root_module.resources[] | select(.address == "aws_budgets_budget.account_cost")][0]
        | all(.values.notification[];
          .subscriber_email_addresses == ["unsafe@example.com"])
      ' "${state_file}" >/dev/null
      jq -e '.Subscribers == [{
        SubscriptionType: "EMAIL",
        Address: "unsafe@example.com"
      }]' "${live_file}" >/dev/null
      ;;
  esac

  expect_verification_failure before "${case_name}"
  mv "${reviewed_file}" "${documents_file}"
}

for paired_case in \
  paired-wildcard-github-subject \
  paired-additional-github-audience \
  paired-broadened-human-trust \
  paired-additional-administration-permission \
  paired-state-object-deletion \
  paired-public-bucket-grant \
  paired-missing-boundary \
  paired-replaced-boundary \
  paired-budget-recipient; do
  run_paired_state_and_aws_mutation "${paired_case}"
done

documents_file="${fixture_root}/actual-documents.json"
budget_account_recovery="${test_root}/budget-account.reviewed.json"
budget_account_mutation="${test_root}/budget-account.mutated.json"
cp "${documents_file}" "${budget_account_recovery}"
jq '.budget.account_id = null' "${documents_file}" >"${budget_account_mutation}"
mv "${budget_account_mutation}" "${documents_file}"
jq -e '.budget.account_id == null' "${documents_file}" >/dev/null
expect_verification_failure before state-missing-budget-account
mv "${budget_account_recovery}" "${documents_file}"

lifecycle_recovery="${test_root}/state-lifecycle.reviewed.json"
lifecycle_mutation="${test_root}/state-lifecycle.mutated.json"
cp "${documents_file}" "${lifecycle_recovery}"
jq '.state_lifecycle[0].filter[0].object_size_greater_than = 1' \
  "${documents_file}" >"${lifecycle_mutation}"
mv "${lifecycle_mutation}" "${documents_file}"
jq -e '.state_lifecycle[0].filter[0].object_size_greater_than == 1' \
  "${documents_file}" >/dev/null
expect_verification_failure before state-extra-lifecycle-filter
mv "${lifecycle_recovery}" "${documents_file}"

for failing_scenario in \
  access-key \
  changed-budget-notification \
  changed-budget-subscriber \
  changed-bucket-lifecycle \
  changed-bucket-policy \
  changed-role-inline-policy \
  changed-temporary-policy \
  changed-boundary-policy \
  disabled-public-access-block \
  extra-audience \
  extra-role-policy \
  extra-role-inline-policy \
  extra-temporary-policy-entity \
  extra-user-inline \
  extra-user-policy \
  group \
  iam-error-redaction \
  iam-unrelated-not-found-error \
  kms-bucket-encryption \
  missing-mfa \
  object-writer-ownership \
  suspended-bucket-versioning \
  user-boundary \
  wrong-budget-amount \
  wrong-budget-cost-types \
  wrong-budget-filter \
  wrong-budget-identity \
  wrong-caller-role \
  wrong-role-boundary \
  wrong-role-session-duration \
  wrong-trust; do
  expect_verification_failure before "${failing_scenario}"
done

if (($(grep -Fc 'wrong-role-boundary|--profile opensearch-lab-admin iam get-role --role-name opensearch-lab-terraform-admin' \
  "${call_trace_file}") != 1)); then
  echo 'A structural IAM mismatch was retried.' >&2
  exit 1
fi
printf 'negative case check: structural-iam-mismatch-not-retried\n'

if (($(grep -Fc 'iam-unrelated-not-found-error|--profile opensearch-lab-admin iam get-user' \
  "${call_trace_file}") != 1)); then
  echo 'An unrelated IAM error was retried.' >&2
  exit 1
fi
printf 'negative case check: unrelated-iam-error-not-retried\n'

expect_verification_failure after temporary-policy-still-exists
if (($(grep -Fc 'temporary-policy-still-exists|--profile opensearch-lab-admin iam get-policy --policy-arn' \
  "${call_trace_file}") != 7)); then
  echo 'The bounded IAM deletion retry case did not use the expected attempts.' >&2
  exit 1
fi

printf 'Bootstrap access allow-list safeguards passed (%d negative cases).\n' \
  "${negative_case_count}"
