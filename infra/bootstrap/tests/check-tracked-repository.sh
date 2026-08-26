#!/usr/bin/env bash

set -euo pipefail

if (($# != 0)); then
  echo "This command does not accept arguments." >&2
  exit 1
fi

for command_name in awk git grep jq unzip; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${command_name}" >&2
    exit 1
  fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
cd "${repository_root}"

validation_workflow=".github/workflows/terraform-validate.yml"
oidc_workflow=".github/workflows/verify-aws-oidc.yml"

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

for required_workflow in "${validation_workflow}" "${oidc_workflow}"; do
  if ! git ls-files --error-unmatch "${required_workflow}" >/dev/null 2>&1 ||
    [[ ! -f "${required_workflow}" ]] || [[ -L "${required_workflow}" ]]; then
    echo "A reviewed workflow is not a tracked regular file." >&2
    exit 1
  fi
done

tracked_file_count=0
while IFS= read -r -d '' tracked_file; do
  tracked_file_count=$((tracked_file_count + 1))

  case "${tracked_file}" in
    kubeconfig.example | */kubeconfig.example | *.kubeconfig.example)
      ;;
    .kube/* | */.kube/* | kubeconfig | */kubeconfig | \
      kubeconfig.* | */kubeconfig.* | *.kubeconfig)
      echo "A kubeconfig is tracked." >&2
      exit 1
      ;;
    .private/* | */.private/* | .aws/* | */.aws/* | \
      .terraform/* | */.terraform/* | backend.tf | */backend.tf | \
      *.tfstate | *.tfstate.* | *.tfplan | tfplan | */tfplan | \
      *.tfvars | *.tfvars.json | temporary-bootstrap-policy.json | \
      */temporary-bootstrap-policy.json)
      echo "A generated, private, state or plan artefact is tracked." >&2
      exit 1
      ;;
  esac

  if [[ -f "${tracked_file}" ]] && [[ ! -L "${tracked_file}" ]] && jq -e '
    type == "object"
    and has("version")
    and has("terraform_version")
    and has("serial")
    and has("lineage")
    and has("resources")
  ' "${tracked_file}" >/dev/null 2>&1; then
    echo "Terraform state content is tracked under a disguised filename." >&2
    exit 1
  fi

  if [[ -f "${tracked_file}" ]] && [[ ! -L "${tracked_file}" ]] && {
    jq -e '
      type == "object"
      and .apiVersion == "v1"
      and .kind == "Config"
      and (.clusters | type == "array")
      and (.contexts | type == "array")
      and (.users | type == "array")
      and has("current-context")
    ' "${tracked_file}" >/dev/null 2>&1 ||
      awk '
        /^[[:space:]]*apiVersion:[[:space:]]*v1[[:space:]]*$/ { api_version = 1 }
        /^[[:space:]]*kind:[[:space:]]*Config[[:space:]]*$/ { kind = 1 }
        /^[[:space:]]*clusters:[[:space:]]*($|\[)/ { clusters = 1 }
        /^[[:space:]]*contexts:[[:space:]]*($|\[)/ { contexts = 1 }
        /^[[:space:]]*current-context:[[:space:]]*/ { current_context = 1 }
        /^[[:space:]]*users:[[:space:]]*($|\[)/ { users = 1 }
        END {
          exit !(api_version && kind && clusters && contexts && current_context && users)
        }
      ' "${tracked_file}"
  }; then
    echo "Kubeconfig content is tracked under a disguised filename." >&2
    exit 1
  fi

  if [[ -f "${tracked_file}" ]] && [[ ! -L "${tracked_file}" ]] && jq -e '
    type == "object"
    and has("format_version")
    and has("terraform_version")
    and has("planned_values")
    and has("resource_changes")
    and has("configuration")
  ' "${tracked_file}" >/dev/null 2>&1; then
    echo "Terraform plan JSON is tracked under a disguised filename." >&2
    exit 1
  fi

  if [[ -f "${tracked_file}" ]] && [[ ! -L "${tracked_file}" ]]; then
    archive_entries="$(unzip -Z1 "./${tracked_file}" 2>/dev/null || true)"
    if grep -Fqx 'tfplan' <<<"${archive_entries}" &&
      grep -Fqx 'tfstate' <<<"${archive_entries}" &&
      grep -Fqx 'tfstate-prev' <<<"${archive_entries}"; then
      echo "A Terraform plan archive is tracked under a disguised filename." >&2
      exit 1
    fi
  fi
done < <(git ls-files -z)

if ((tracked_file_count == 0)); then
  echo "The repository has no tracked files to inspect." >&2
  exit 1
fi

if git grep -I -qE 'arn:[a-z0-9-]+:iam::[0-9]{12}:' -- .; then
  echo "An account-specific IAM ARN is present in tracked content." >&2
  exit 1
fi

if git grep -I -qE '(^|[^[:alnum:]])[0-9]{12}([^[:alnum:]]|$)' -- .; then
  echo "A possible AWS account ID is present in tracked content." >&2
  exit 1
fi

if git grep -I -qE '(^|[^A-Z0-9])(A3T[A-Z0-9]|ABIA|ACCA|AGPA|AIDA|AIPA|AKIA|ANPA|ANVA|AROA|ASCA|ASIA)[A-Z0-9]{16}([^A-Z0-9]|$)' -- .; then
  echo "An AWS access-key identifier is present in tracked content." >&2
  exit 1
fi

secret_key_name_lower="$(printf '%s%s' aws_secret_ access_key)"
secret_key_name_upper="$(printf '%s%s' AWS_SECRET_ ACCESS_KEY)"
secret_assignment_pattern="[\"']?(${secret_key_name_lower}|${secret_key_name_upper})[\"']?[[:space:]]*[:=]"
if git grep -I -qE "${secret_assignment_pattern}" -- .; then
  echo "An AWS secret-access-key assignment is present in tracked content." >&2
  exit 1
fi

if git grep -I -qE '(^|[^[:alnum:]_])(gh[pousr]_[[:alnum:]]{36,}|github_pat_[[:alnum:]_]{20,})([^[:alnum:]_]|$)' -- .; then
  echo "A GitHub token is present in tracked content." >&2
  exit 1
fi

private_key_label="$(printf '%s%s' PRIVATE ' KEY')"
private_key_types="$(printf '%s%s' 'RSA|EC|DSA|ENCRYPTED|OPEN' SSH)"
key_marker_pattern="-----BEGIN ((${private_key_types}) )?${private_key_label}-----"
if git grep -I -qE -e "${key_marker_pattern}" -- .; then
  echo "A private key is present in tracked content." >&2
  exit 1
fi

expected_validation_trigger=$'on:\n  pull_request:\n  push:\n    branches:\n      - main'
actual_validation_trigger="$(awk '
  /^on:$/ { capture = 1 }
  /^permissions:$/ { capture = 0 }
  capture { print }
' "${validation_workflow}")"
if [[ "${actual_validation_trigger}" != "${expected_validation_trigger}" ]]; then
  echo "The validation workflow trigger differs from the reviewed contract." >&2
  exit 1
fi

expected_oidc_trigger=$'on:\n  workflow_dispatch:'
actual_oidc_trigger="$(awk '
  /^on:$/ { capture = 1 }
  /^permissions:$/ { capture = 0 }
  capture { print }
' "${oidc_workflow}")"
if [[ "${actual_oidc_trigger}" != "${expected_oidc_trigger}" ]]; then
  echo "The AWS OIDC workflow must remain manually dispatched." >&2
  exit 1
fi

workflow_count=0
action_count=0
runner_count=0
expected_read_only_permissions=$'permissions:\n  contents: read'
expected_oidc_permissions=$'permissions:\n  contents: read\n  id-token: write'
local_action_stack="|"
visited_local_actions="|"
uses_pattern="^[[:space:]]*(-[[:space:]]+)?([\"']?uses[\"']?)[[:space:]]*:"

check_restricted_yaml_keys() {
  local yaml_file="$1"

  if grep -Eq "^[[:space:]]*(-[[:space:]]+)?[\"'].*[\"'][[:space:]]*:" \
    "${yaml_file}" || grep -Eq '^[[:space:]]*\?' "${yaml_file}"; then
    echo "Quoted or complex YAML mapping keys are not allowed in workflows or actions." >&2
    exit 1
  fi
  if grep -Eq '^[[:space:]]*(-[[:space:]]+)?[!&*]' "${yaml_file}" ||
    grep -Eq ':[[:space:]]*[!&*]' "${yaml_file}"; then
    echo "YAML tags, anchors and aliases are not allowed in workflows or actions." >&2
    exit 1
  fi
  if grep -Eq '^[[:space:]]*\{' "${yaml_file}" ||
    grep -Eq '^[[:space:]]*([^#[:space:]][^:]*:[[:space:]]*|-[[:space:]]*)\{' \
      "${yaml_file}"; then
    echo "Flow-style YAML mappings are not allowed in workflows or actions." >&2
    exit 1
  fi
}

extract_action_reference() {
  local uses_line="$1"
  local action_reference="${uses_line#*:}"
  action_reference="${action_reference%%#*}"
  trim_whitespace "${action_reference}"
}

check_action_metadata_file() {
  local metadata_file="$1"
  local previous_stack
  local uses_line

  if [[ ! -f "${metadata_file}" ]] || [[ -L "${metadata_file}" ]]; then
    echo "A local action metadata file is not a tracked regular file." >&2
    exit 1
  fi
  if [[ "${local_action_stack}" == *"|${metadata_file}|"* ]]; then
    echo "A local composite action reference cycle is not allowed." >&2
    exit 1
  fi
  if [[ "${visited_local_actions}" == *"|${metadata_file}|"* ]]; then
    return
  fi

  previous_stack="${local_action_stack}"
  local_action_stack="${local_action_stack}${metadata_file}|"
  check_restricted_yaml_keys "${metadata_file}"
  while IFS= read -r uses_line; do
    check_action_reference "$(extract_action_reference "${uses_line}")"
  done < <(grep -E "${uses_pattern}" "${metadata_file}" || true)
  local_action_stack="${previous_stack}"
  visited_local_actions="${visited_local_actions}${metadata_file}|"
}

check_action_reference() {
  local action_reference="$1"
  local local_reference
  local metadata_file=""

  action_count=$((action_count + 1))

  case "${action_reference%%@*}" in
    actions/upload-artifact | actions/upload-artifact/* | \
      actions/upload-pages-artifact | actions/upload-pages-artifact/*)
      echo "Artifact upload actions require an explicit reviewed allow-list." >&2
      exit 1
      ;;
  esac

  if [[ "${action_reference}" == ./* ]]; then
    local_reference="${action_reference#./}"
    if [[ ! "${local_reference}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] ||
      [[ "/${local_reference}/" == *"/../"* ]] ||
      [[ "/${local_reference}/" == *"/./"* ]]; then
      echo "A local workflow action reference is invalid or escapes its reviewed path." >&2
      exit 1
    fi

    case "${local_reference}" in
      .github/workflows/*.yml | .github/workflows/*.yaml)
        if ! git ls-files --error-unmatch "${local_reference}" >/dev/null 2>&1 ||
          [[ ! -f "${local_reference}" ]] || [[ -L "${local_reference}" ]]; then
          echo "A local reusable workflow reference is not a tracked regular file." >&2
          exit 1
        fi
        return
        ;;
    esac

    if git ls-files --error-unmatch \
      "${local_reference}/action.yml" >/dev/null 2>&1; then
      metadata_file="${local_reference}/action.yml"
    fi
    if git ls-files --error-unmatch \
      "${local_reference}/action.yaml" >/dev/null 2>&1; then
      if [[ -n "${metadata_file}" ]]; then
        echo "A local action directory has ambiguous tracked metadata." >&2
        exit 1
      fi
      metadata_file="${local_reference}/action.yaml"
    fi
    if [[ -z "${metadata_file}" ]] || [[ ! -f "${metadata_file}" ]] ||
      [[ -L "${metadata_file}" ]]; then
      echo "A local workflow action directory has no tracked regular action metadata." >&2
      exit 1
    fi

    check_action_metadata_file "${metadata_file}"
    return
  fi

  if [[ "${action_reference}" =~ ^docker://[^@]+@sha256:[0-9a-f]{64}$ ]]; then
    return
  fi
  if [[ ! "${action_reference}" =~ ^[^[:space:]@]+/[^[:space:]@]+@[0-9a-f]{40}$ ]]; then
    echo "A third-party workflow action is not pinned to an immutable digest." >&2
    exit 1
  fi
}

while IFS= read -r workflow_file; do
  [[ -n "${workflow_file}" ]] || continue
  if [[ ! -f "${workflow_file}" ]] || [[ -L "${workflow_file}" ]]; then
    echo "A workflow is not a tracked regular file." >&2
    exit 1
  fi
  workflow_count=$((workflow_count + 1))
  workflow_runner_count=0
  check_restricted_yaml_keys "${workflow_file}"

  while IFS= read -r runner_line; do
    runner="${runner_line#*:}"
    runner="${runner%%#*}"
    runner="$(trim_whitespace "${runner}")"
    workflow_runner_count=$((workflow_runner_count + 1))
    runner_count=$((runner_count + 1))

    if [[ "${runner}" != "ubuntu-24.04" ]]; then
      echo "A workflow runner differs from the reviewed ubuntu-24.04 image." >&2
      exit 1
    fi
  done < <(grep -E '^[[:space:]]*runs-on:' "${workflow_file}")

  if ((workflow_runner_count == 0)); then
    echo "A workflow has no explicit reviewed runner." >&2
    exit 1
  fi

  while IFS= read -r uses_line; do
    check_action_reference "$(extract_action_reference "${uses_line}")"
  done < <(grep -E "${uses_pattern}" "${workflow_file}" || true)

  if grep -Eq "^[[:space:]]+[\"']?permissions[\"']?[[:space:]]*:" "${workflow_file}"; then
    echo "Job-level workflow permissions are not allowed." >&2
    exit 1
  fi

  if grep -Eq '^[[:space:]]*(actions|attestations|checks|contents|deployments|discussions|issues|packages|pages|pull-requests|repository-projects|security-events|statuses):[[:space:]]*write([[:space:]]*#.*)?$' "${workflow_file}"; then
    echo "A workflow grants an unreviewed write permission." >&2
    exit 1
  fi

  id_token_count="$(grep -Ec '^[[:space:]]*id-token:[[:space:]]*write([[:space:]]*#.*)?$' "${workflow_file}" || true)"
  if [[ "${workflow_file}" == "${oidc_workflow}" ]]; then
    if [[ "${id_token_count}" != "1" ]] ||
      ! grep -Fqx "    if: github.ref == 'refs/heads/main'" "${workflow_file}" ||
      ! grep -Fqx '    environment: aws-bootstrap' "${workflow_file}"; then
      echo "The manual AWS OIDC workflow differs from its reviewed token boundary." >&2
      exit 1
    fi
  elif [[ "${id_token_count}" != "0" ]]; then
    echo "ID-token write access exists outside the reviewed AWS OIDC workflow." >&2
    exit 1
  fi

  actual_permissions="$(awk '
    /^permissions:$/ { capture = 1 }
    /^jobs:$/ { capture = 0 }
    capture { print }
  ' "${workflow_file}")"
  if [[ "${workflow_file}" == "${oidc_workflow}" ]]; then
    expected_permissions="${expected_oidc_permissions}"
  else
    expected_permissions="${expected_read_only_permissions}"
  fi
  if [[ "${actual_permissions}" != "${expected_permissions}" ]]; then
    echo "A workflow permissions block differs from its reviewed contract." >&2
    exit 1
  fi
done < <(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')

while IFS= read -r -d '' action_metadata_file; do
  check_action_metadata_file "${action_metadata_file}"
done < <(git ls-files -z 'action.yml' 'action.yaml' '*/action.yml' '*/action.yaml')

if ((workflow_count == 0 || runner_count == 0)); then
  echo "No tracked workflows were inspected." >&2
  exit 1
fi

printf 'Tracked repository safeguards passed: %d files, %d workflows, %d actions, %d runners.\n' \
  "${tracked_file_count}" "${workflow_count}" "${action_count}" "${runner_count}"
