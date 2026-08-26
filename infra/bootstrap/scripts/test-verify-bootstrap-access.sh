#!/usr/bin/env bash

set -euo pipefail

source_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
test_root="$(mktemp -d)"
trap 'rm -rf -- "${test_root}"' EXIT
account_id="$(printf '%06d%06d' 123 456)"
fixture_root="${test_root}/fixture"

mkdir -p \
  "${fixture_root}/bin" \
  "${fixture_root}/infra/bootstrap/policies" \
  "${fixture_root}/infra/bootstrap/scripts"
git -C "${fixture_root}" init -q
cp "${source_root}/.gitignore" "${fixture_root}/.gitignore"
cp "${source_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json" \
  "${fixture_root}/infra/bootstrap/policies/temporary-bootstrap-policy.template.json"
cp "${source_root}/infra/bootstrap/scripts/generate-temporary-policy.sh" \
  "${fixture_root}/infra/bootstrap/scripts/generate-temporary-policy.sh"
cp "${source_root}/infra/bootstrap/scripts/verify-bootstrap-access.sh" \
  "${fixture_root}/infra/bootstrap/scripts/verify-bootstrap-access.sh"
printf 'terraform { backend "s3" {} }\n' >"${fixture_root}/infra/bootstrap/backend.tf"

jq -n --arg account_id "${account_id}" '
  {
    user_inline: {
      Version: "2012-10-17",
      Statement: [{
        Sid: "AssumeExactTerraformAdminRole",
        Effect: "Allow",
        Action: "sts:AssumeRole",
        Resource: ("arn:aws:iam::" + $account_id + ":role/opensearch-lab-terraform-admin")
      }]
    },
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
              address: "aws_iam_user_policy.bootstrap_user_assume_role",
              values: {policy: ($documents.user_inline | tojson)}
            },
            {
              address: "aws_iam_role.terraform_admin",
              values: {assume_role_policy: ($documents.human_trust | tojson)}
            },
            {
              address: "aws_iam_role_policy.terraform_admin",
              values: {policy: ($documents.human_inline | tojson)}
            },
            {
              address: "aws_iam_role.github_actions",
              values: {assume_role_policy: ($documents.github_trust | tojson)}
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
  *" sts get-caller-identity "*)
    jq -nc --arg account_id "${account_id}" '{
      Account: $account_id,
      Arn: (
        "arn:aws:sts::" + $account_id
        + ":assumed-role/opensearch-lab-terraform-admin/verification"
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
    jq -nc '{PolicyNames:["opensearch-lab-assume-terraform-admin"]}'
    ;;
  *" iam get-user-policy "*)
    jq -c '{PolicyDocument:.user_inline}' "${documents_file}"
    ;;
  *" iam get-role-policy "*)
    if [[ "$*" == *"opensearch-lab-terraform-admin"* ]]; then
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
    else
      jq -nc '{PolicyNames:["opensearch-lab-bootstrap-state"]}'
    fi
    ;;
  *" iam get-role "*)
    if [[ "$*" == *"opensearch-lab-terraform-admin"* ]]; then
      if [[ "${FAKE_SCENARIO:-}" == "wrong-trust" ]]; then
        jq -nc '{Role:{RoleName:"opensearch-lab-terraform-admin",AssumeRolePolicyDocument:{}}}'
      else
        jq -c '{Role:{RoleName:"opensearch-lab-terraform-admin",AssumeRolePolicyDocument:.human_trust}}' \
          "${documents_file}"
      fi
    else
      jq -c '{Role:{RoleName:"opensearch-lab-github-actions",AssumeRolePolicyDocument:.github_trust}}' \
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
    if [[ "${FAKE_SCENARIO:-}" == "changed-temporary-policy" ]]; then
      jq -c '{PolicyVersion:{Document:(.Statement[0].Sid = "Changed"),VersionId:"v1",IsDefaultVersion:true}}' \
        "${temporary_policy}"
    else
      jq -c '{PolicyVersion:{Document:.,VersionId:"v1",IsDefaultVersion:true}}' \
        "${temporary_policy}"
    fi
    ;;
  *" iam list-entities-for-policy "*)
    jq -nc '{
      PolicyGroups:[],
      PolicyRoles:[],
      PolicyUsers:[{UserName:"opensearch-lab-bootstrap"}]
    }'
    ;;
  *" iam get-policy "*)
    if [[ "${FAKE_PHASE}" == "after" ]]; then
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

for failing_scenario in \
  access-key \
  changed-temporary-policy \
  extra-audience \
  extra-role-policy \
  extra-user-policy \
  group \
  user-boundary \
  wrong-trust; do
  if run_verification before "${failing_scenario}" >/dev/null 2>&1; then
    echo "Access verification accepted scenario: ${failing_scenario}" >&2
    exit 1
  fi
done

echo "Bootstrap access allow-list safeguards passed."
