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
  aws_s3_bucket.state \
  aws_s3_bucket_lifecycle_configuration.state \
  aws_s3_bucket_ownership_controls.state \
  aws_s3_bucket_policy.state \
  aws_s3_bucket_public_access_block.state \
  aws_s3_bucket_server_side_encryption_configuration.state \
  aws_s3_bucket_versioning.state | sort)"

actual_resources="$(awk '
  /^[[:space:]]*resource[[:space:]]+"[^"]+"[[:space:]]+"[^"]+"[[:space:]]*\{[[:space:]]*$/ {
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

module_count="$(awk '/^[[:space:]]*module[[:space:]]+"[^"]+"[[:space:]]*\{[[:space:]]*$/ { count++ } END { print count + 0 }' "$bootstrap_dir"/*.tf)"
if [[ "$module_count" -ne 0 ]]; then
  printf 'Bootstrap configuration must not load unreviewed root modules.\n' >&2
  exit 1
fi

has_exact_boundary() {
  local configuration_file="$1"
  local resource_name="$2"
  local expected_expression="$3"

  awk -v expected_name="$resource_name" -v expected_expression="$expected_expression" '
    /^[[:space:]]*resource[[:space:]]+"aws_iam_role"[[:space:]]+"[^"]+"[[:space:]]*\{[[:space:]]*$/ {
      name = $3
      gsub(/"/, "", name)
      if (name == expected_name) {
        inside = 1
        depth = 1
        seen = 1
        next
      }
    }

    inside {
      if ($0 ~ /^[[:space:]]+permissions_boundary[[:space:]]*=/) {
        assignments++
        assignment = $0
        sub(/^[[:space:]]+/, "", assignment)
        if (assignment == "permissions_boundary = " expected_expression) {
          exact = 1
        }
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
      exit !(seen && assignments == 1 && exact)
    }
  ' "$configuration_file"
}

if ! has_exact_boundary \
  "$bootstrap_dir/human-access.tf" \
  terraform_admin \
  local.terraform_admin_boundary_arn; then
  printf 'The human role permissions-boundary assignment differs from its exact contract.\n' >&2
  exit 1
fi

has_exact_lifecycle_filter() {
  awk '
    /^[[:space:]]*resource[[:space:]]+"aws_s3_bucket_lifecycle_configuration"[[:space:]]+"state"[[:space:]]*\{[[:space:]]*$/ {
      inside = 1
      depth = 1
      seen = 1
      next
    }

    inside {
      if (heredoc) {
        candidate = $0
        if (heredoc_indented) {
          sub(/^[[:space:]]+/, "", candidate)
        }
        sub(/[[:space:]]+$/, "", candidate)
        if (candidate == heredoc_marker) {
          heredoc = 0
        }
        next
      }

      entering_heredoc = 0
      if (match($0, /<<-?[A-Za-z_][A-Za-z0-9_]*/)) {
        heredoc_token = substr($0, RSTART, RLENGTH)
        heredoc_indented = substr(heredoc_token, 1, 3) == "<<-"
        heredoc_marker = heredoc_token
        sub(/^<<-?/, "", heredoc_marker)
        entering_heredoc = 1
      }

      starts_rule = depth == 1 &&
        $0 ~ /^[[:space:]]*rule[[:space:]]*\{[[:space:]]*$/
      starts_filter = rule && depth == rule_depth &&
        $0 ~ /^[[:space:]]*filter[[:space:]]*\{[[:space:]]*$/

      if (starts_rule) {
        rule_blocks++
      }
      if (starts_filter) {
        filter_blocks++
      }

      if (filter && depth == filter_depth &&
        $0 !~ /^[[:space:]]*}[[:space:]]*$/ &&
        $0 !~ /^[[:space:]]*(#.*)?$/) {
        if ($0 ~ /^[[:space:]]*prefix[[:space:]]*=[[:space:]]*""[[:space:]]*$/) {
          prefix_assignments++
        } else {
          unexpected_filter_content = 1
        }
      }

      line = $0
      opens = gsub(/{/, "{", line)
      line = $0
      closes = gsub(/}/, "}", line)
      depth += opens - closes

      if (starts_rule) {
        rule = 1
        rule_depth = depth
      } else if (rule && depth < rule_depth) {
        rule = 0
      }

      if (starts_filter) {
        filter = 1
        filter_depth = depth
      } else if (filter && depth < filter_depth) {
        filter = 0
      }

      if (entering_heredoc) {
        heredoc = 1
      }
      if (depth == 0) {
        inside = 0
      }
    }

    END {
      exit !(seen && rule_blocks == 1 && filter_blocks == 1 &&
        prefix_assignments == 1 && !unexpected_filter_content)
    }
  ' "$state_file"
}

if ! has_exact_lifecycle_filter; then
  printf 'The state lifecycle filter differs from its exact all-object contract.\n' >&2
  exit 1
fi

if ! has_exact_boundary \
  "$bootstrap_dir/github-oidc.tf" \
  github_actions \
  local.github_actions_boundary_arn; then
  printf 'The GitHub role permissions-boundary assignment differs from its exact contract.\n' >&2
  exit 1
fi

has_prevent_destroy() {
  local resource_type="$1"
  local resource_name="$2"

  awk -v expected_type="$resource_type" -v expected_name="$resource_name" '
    /^[[:space:]]*resource[[:space:]]+"[^"]+"[[:space:]]+"[^"]+"[[:space:]]*\{[[:space:]]*$/ {
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
      if (heredoc) {
        candidate = $0
        if (heredoc_indented) {
          sub(/^[[:space:]]+/, "", candidate)
        }
        sub(/[[:space:]]+$/, "", candidate)
        if (candidate == heredoc_marker) {
          heredoc = 0
        }
        next
      }

      entering_heredoc = 0
      if (match($0, /<<-?[A-Za-z_][A-Za-z0-9_]*/)) {
        heredoc_token = substr($0, RSTART, RLENGTH)
        heredoc_indented = substr(heredoc_token, 1, 3) == "<<-"
        heredoc_marker = heredoc_token
        sub(/^<<-?/, "", heredoc_marker)
        entering_heredoc = 1
      }

      starts_lifecycle = depth == 1 &&
        $0 ~ /^[[:space:]]*lifecycle[[:space:]]*\{[[:space:]]*$/
      if (starts_lifecycle) {
        lifecycle_blocks++
      }

      if (lifecycle && depth == lifecycle_depth &&
        $0 ~ /^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true[[:space:]]*$/) {
        prevent_assignments++
        protected = 1
      }

      line = $0
      opens = gsub(/{/, "{", line)
      line = $0
      closes = gsub(/}/, "}", line)
      depth += opens - closes

      if (starts_lifecycle) {
        lifecycle = 1
        lifecycle_depth = depth
      } else if (lifecycle && depth < lifecycle_depth) {
        lifecycle = 0
      }

      if (entering_heredoc) {
        heredoc = 1
      }

      if (depth == 0) {
        inside = 0
      }
    }

    END {
      exit !(seen && lifecycle_blocks == 1 && prevent_assignments == 1 && protected)
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

printf 'Static bootstrap contracts passed: 13 allowed resources, 2 exact role boundaries, 1 all-object lifecycle filter, 0 modules, 7 destroy guards.\n'
