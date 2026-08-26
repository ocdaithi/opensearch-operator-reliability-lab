#!/usr/bin/env bash
set -euo pipefail

bootstrap_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_file="$bootstrap_dir/state.tf"
shopt -s nullglob

json_configuration=("$bootstrap_dir"/*.tf.json)
if ((${#json_configuration[@]} != 0)); then
  printf 'Bootstrap JSON configuration bypasses the reviewed resource inventory.\n' >&2
  exit 1
fi

expected_resources="$(printf '%s\n' \
  aws_budgets_budget.account_cost \
  aws_iam_openid_connect_provider.github \
  aws_iam_role.github_actions \
  aws_iam_role.terraform_admin \
  aws_iam_role_policy.github_actions_state \
  aws_iam_role_policy.terraform_admin \
  aws_iam_user_policy.bootstrap_user_assume_role \
  aws_s3_bucket.state \
  aws_s3_bucket_lifecycle_configuration.state \
  aws_s3_bucket_ownership_controls.state \
  aws_s3_bucket_policy.state \
  aws_s3_bucket_public_access_block.state \
  aws_s3_bucket_server_side_encryption_configuration.state \
  aws_s3_bucket_versioning.state | sort)"

actual_resources="$(awk '
  /^resource "[^"]+" "[^"]+" \{$/ {
    type = $2
    name = $3
    gsub(/"/, "", type)
    gsub(/"/, "", name)
    print type "." name
  }
' "$bootstrap_dir"/*.tf | sort)"

if [[ "$actual_resources" != "$expected_resources" ]]; then
  printf 'Bootstrap resource inventory differs from the reviewed allow-list.\n' >&2
  diff -u <(printf '%s\n' "$expected_resources") <(printf '%s\n' "$actual_resources") >&2 || true
  exit 1
fi

module_count="$(awk '/^module "[^"]+" \{$/ { count++ } END { print count + 0 }' "$bootstrap_dir"/*.tf)"
if [[ "$module_count" -ne 0 ]]; then
  printf 'Bootstrap configuration must not load unreviewed root modules.\n' >&2
  exit 1
fi

has_prevent_destroy() {
  local resource_type="$1"
  local resource_name="$2"

  awk -v expected_type="$resource_type" -v expected_name="$resource_name" '
    /^resource "[^"]+" "[^"]+" \{$/ {
      type = $2
      name = $3
      gsub(/"/, "", type)
      gsub(/"/, "", name)

      if (type == expected_type && name == expected_name) {
        inside = 1
        depth = 1
        seen = 1
        next
      }
    }

    inside {
      if ($0 ~ /^[[:space:]]+prevent_destroy = true$/) {
        protected = 1
      }

      line = $0
      opens = gsub(/{/, "{", line)
      line = $0
      closes = gsub(/}/, "}", line)
      depth += opens - closes

      if (depth == 0) {
        inside = 0
      }
    }

    END {
      exit !(seen && protected)
    }
  ' "$state_file"
}

protected_resources=(
  aws_s3_bucket.state
  aws_s3_bucket_public_access_block.state
  aws_s3_bucket_ownership_controls.state
  aws_s3_bucket_versioning.state
  aws_s3_bucket_server_side_encryption_configuration.state
  aws_s3_bucket_lifecycle_configuration.state
  aws_s3_bucket_policy.state
)

for resource in "${protected_resources[@]}"; do
  resource_type="${resource%%.*}"
  resource_name="${resource#*.}"
  if ! has_prevent_destroy "$resource_type" "$resource_name"; then
    printf 'Missing prevent_destroy on %s.\n' "$resource" >&2
    exit 1
  fi
done

printf 'Static bootstrap contracts passed: 14 allowed resources, 0 modules, 7 destroy guards.\n'
