#!/usr/bin/env bash

set -euo pipefail

case "${1:-}" in
  --approved)
    operation="migrate"
    ;;
  --resume-verification)
    operation="resume-verification"
    ;;
  *)
    echo "Refusing to migrate state without the explicit --approved flag." >&2
    exit 1
    ;;
esac

if (($# > 2)) || [[ "${2:-}" == --* ]]; then
  echo "Usage: migrate-state.sh <--approved|--resume-verification> [variables-file]" >&2
  exit 1
fi

for command_name in aws git jq terraform; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command is unavailable: ${command_name}" >&2
    exit 1
  fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
module_dir="${repository_root}/infra/bootstrap"
private_dir="${repository_root}/.private/terraform-bootstrap"
variables_file="${2:-${private_dir}/terraform.tfvars}"
backend_file="${module_dir}/backend.tf"
backend_cache_file="${module_dir}/.terraform/terraform.tfstate"
local_backend_example="${module_dir}/backend.local.tf.example"
backend_contract_script="${module_dir}/scripts/check-backend-contract.sh"
local_state_file="${private_dir}/terraform.tfstate"
verification_plan="${private_dir}/post-migration-lock-check.tfplan"
state_key="bootstrap/terraform.tfstate"
lock_key="${state_key}.tflock"
aws_profile="opensearch-lab-terraform"
migration_lock_dir="${private_dir}/.migrate-state.lock"

if [[ -L "${private_dir}" ]]; then
  echo "The private Terraform directory must not be a symbolic link." >&2
  exit 1
fi
if [[ "${operation}" == "resume-verification" ]]; then
  if [[ ! -d "${private_dir}" ]]; then
    echo "The private Terraform directory containing migration evidence is missing." >&2
    exit 1
  fi
else
  mkdir -p "${private_dir}"
  chmod 700 "${private_dir}"
fi
umask 077

if ! mkdir "${migration_lock_dir}" 2>/dev/null; then
  echo "Another state migration invocation is already in progress." >&2
  exit 1
fi
lock_held=true

release_initial_lock() {
  local exit_status=$?

  trap - EXIT
  if ! rmdir "${migration_lock_dir}"; then
    echo "Could not release the state-migration invocation lock." >&2
  fi
  if ((exit_status == 0)); then
    exit_status=1
  fi
  exit "${exit_status}"
}
trap release_initial_lock EXIT

if [[ ! -x "${backend_contract_script}" ]]; then
  echo "The exact backend-contract checker is unavailable." >&2
  exit 1
fi
"${backend_contract_script}" local "${local_backend_example}" >/dev/null

if [[ "${operation}" == "migrate" ]]; then
  "${backend_contract_script}" local "${backend_file}" >/dev/null
fi

if [[ ! -f "${variables_file}" ]]; then
  echo "The private Terraform variable file is missing." >&2
  exit 1
fi

if [[ "${operation}" == "migrate" ]] &&
  [[ ! -s "${local_state_file}" || ! -f "${local_state_file}" ]]; then
  echo "The original local state is missing or empty." >&2
  exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_id="${timestamp}-$$"
recovery_state="${private_dir}/pre-migration-${run_id}.tfstate"
remote_state="${private_dir}/post-migration-${run_id}.tfstate"
backend_recovery="${private_dir}/pre-migration-backend-${run_id}.tf"
backend_cache_recovery="${private_dir}/pre-migration-backend-cache-${run_id}.tfstate"
temporary_backend=""
temporary_local_state_pull=""
temporary_local_state_restore=""
temporary_remote_state=""
temporary_resume_remote_state=""
retained_remote_state=""
cached_backend_should_exist=false
cache_may_have_been_mutated=false
backend_recovery_ready=false
backend_cache_recovery_ready=false
local_state_recovery_ready=false
migration_phase="pre-write"

file_mode() {
  local file="$1"

  if stat -f '%Lp' "${file}" >/dev/null 2>&1; then
    stat -f '%Lp' "${file}"
  else
    stat -c '%a' "${file}"
  fi
}

backend_original_mode=""
local_state_original_mode=""
backend_cache_original_mode=""

if [[ "${operation}" == "migrate" ]]; then
  backend_original_mode="$(file_mode "${backend_file}")"
  local_state_original_mode="$(file_mode "${local_state_file}")"
fi

# `terraform state pull` can upgrade the state to the local CLI version:
# https://developer.hashicorp.com/terraform/cli/commands/state/pull
# terraform_version is therefore the sole field allowed to differ. Lineage,
# serial and every managed-state value must remain identical.
states_match() {
  local expected_state="$1"
  local actual_state="$2"

  jq -e -s '
    length == 2
    and all(.[]; type == "object")
    and (.[0].lineage | type == "string" and length > 0)
    and (.[1].lineage | type == "string" and length > 0)
    and (.[0].serial | type == "number" and . >= 0 and floor == .)
    and (.[1].serial | type == "number" and . >= 0 and floor == .)
    and (.[0].terraform_version | type == "string" and length > 0)
    and (.[1].terraform_version | type == "string" and length > 0)
    and .[0].lineage == .[1].lineage
    and .[0].serial == .[1].serial
    and (.[0] | del(.terraform_version)) == (.[1] | del(.terraform_version))
  ' "${expected_state}" "${actual_state}" >/dev/null
}

# Terraform 1.15.9 stores check aggregates and their objects in address maps,
# whose iteration order is not stable when a state is serialised. This
# comparison validates the complete v4 schema, rejects duplicate check
# identities, and canonicalises only those two unordered arrays. All other
# logical state remains byte-for-byte equivalent at the JSON value level.
state_equivalence_matches() {
  local expected_state="$1"
  local actual_state="$2"
  local metadata_contract="$3"

  jq -e -s --arg metadata_contract "${metadata_contract}" '
    def has_only_keys($allowed):
      ((keys - $allowed) | length) == 0;
    def has_all_keys($required):
      (($required - keys) | length) == 0;
    def is_unsigned_integer:
      type == "number" and . >= 0 and floor == .;
    def is_terraform_version:
      type == "string"
      and test("^[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.+-]+)?$");
    def is_check_status:
      type == "string" and IN("pass", "fail", "error", "unknown");
    def valid_output:
      type == "object"
      and has_only_keys(["value", "type", "sensitive"])
      and has_all_keys(["value", "type"])
      and ((.type | type) == "string" or (.type | type) == "array")
      and ((has("sensitive") | not) or (.sensitive | type) == "boolean");
    def valid_instance:
      type == "object"
      and has_only_keys([
        "index_key",
        "status",
        "deposed",
        "schema_version",
        "attributes",
        "attributes_flat",
        "sensitive_attributes",
        "identity_schema_version",
        "identity",
        "private",
        "dependencies",
        "create_before_destroy"
      ])
      and has_all_keys(["schema_version", "identity_schema_version"])
      and (.schema_version | is_unsigned_integer)
      and (.identity_schema_version | is_unsigned_integer)
      and (
        (has("index_key") | not)
        or (.index_key | type) == "string"
        or (.index_key | is_unsigned_integer)
      )
      and (
        (has("status") | not)
        or (.status | type == "string" and IN("", "tainted"))
      )
      and (
        (has("deposed") | not)
        or (.deposed | type == "string" and (length == 0 or length == 8))
      )
      and (
        (has("attributes_flat") | not)
        or (
          (.attributes_flat | type) == "object"
          and all(.attributes_flat[]; type == "string")
        )
      )
      and (
        (has("sensitive_attributes") | not)
        or (.sensitive_attributes | type) == "array"
      )
      and ((has("private") | not) or (.private | type) == "string")
      and (
        (has("dependencies") | not)
        or (
          (.dependencies | type) == "array"
          and all(.dependencies[]; type == "string")
        )
      )
      and (
        (has("create_before_destroy") | not)
        or (.create_before_destroy | type) == "boolean"
      );
    def valid_resource:
      type == "object"
      and has_only_keys([
        "module", "mode", "type", "name", "each", "provider", "instances"
      ])
      and has_all_keys(["mode", "type", "name", "provider", "instances"])
      and (.mode | type == "string" and IN("managed", "data"))
      and (.type | type == "string" and length > 0)
      and (.name | type == "string" and length > 0)
      and (.provider | type == "string" and length > 0)
      and ((has("module") | not) or (.module | type) == "string")
      and ((has("each") | not) or (.each | type) == "string")
      and (.instances | type == "array" and all(.[]; valid_instance));
    def valid_check_object:
      type == "object"
      and has_only_keys(["object_addr", "status", "failure_messages"])
      and has_all_keys(["object_addr", "status"])
      and (.object_addr | type == "string" and length > 0)
      and (.status | is_check_status)
      and (
        (has("failure_messages") | not)
        or .failure_messages == null
        or (
          (.failure_messages | type) == "array"
          and all(.failure_messages[]; type == "string")
        )
      );
    def valid_check_aggregate:
      type == "object"
      and has_only_keys(["object_kind", "config_addr", "status", "objects"])
      and has_all_keys(["object_kind", "config_addr", "status"])
      and (.object_kind | type == "string" and IN("resource", "output", "check", "var"))
      and (.config_addr | type == "string" and length > 0)
      and (.status | is_check_status)
      and (
        (has("objects") | not)
        or .objects == null
        or ((.objects | type) == "array" and all(.objects[]; valid_check_object))
      );
    def valid_state:
      type == "object"
      and has_only_keys([
        "version",
        "terraform_version",
        "serial",
        "lineage",
        "outputs",
        "resources",
        "check_results"
      ])
      and has_all_keys([
        "version",
        "terraform_version",
        "serial",
        "lineage",
        "outputs",
        "resources",
        "check_results"
      ])
      and .version == 4
      and (.terraform_version | is_terraform_version)
      and (.serial | is_unsigned_integer)
      and (.lineage | type == "string" and length > 0)
      and (
        (.outputs | type) == "object"
        and all(.outputs[]; valid_output)
      )
      and (
        (.resources | type) == "array"
        and all(.resources[]; valid_resource)
      )
      and (
        (has("check_results") | not)
        or .check_results == null
        or (
          (.check_results | type) == "array"
          and all(.check_results[]; valid_check_aggregate)
        )
      );
    def has_unique_check_identities:
      (.check_results // []) as $checks
      | ([$checks[] | [.object_kind, .config_addr]]) as $aggregate_ids
      | ($aggregate_ids | length) == ($aggregate_ids | unique | length)
      and all(
        $checks[];
        ([((.objects // [])[]) | .object_addr]) as $object_ids
        | ($object_ids | length) == ($object_ids | unique | length)
      );
    def canonical_check_results:
      [
        .[]
        | {
            object_kind: .object_kind,
            config_addr: .config_addr,
            status: .status,
            objects: (
              [
                (.objects // [])[]
                | {
                    object_addr: .object_addr,
                    status: .status,
                    failure_messages: (.failure_messages // [])
                  }
              ]
              | sort_by(.object_addr)
            )
          }
      ]
      | sort_by([.object_kind, .config_addr]);
    def canonical_logical_state:
      . as $state
      | (
          $state
          | del(.version)
          | del(.terraform_version)
          | del(.serial)
          | del(.lineage)
          | del(.check_results)
        )
        + (
          if ($state | has("check_results")) then
            {
              check_results: (
                if $state.check_results == null then
                  null
                else
                  ($state.check_results | canonical_check_results)
                end
              )
            }
          else
            {}
          end
        );
    def post_migration_metadata_matches:
      .[0].terraform_version == .[1].terraform_version
      and (
        (
          .[0].lineage == .[1].lineage
          and .[0].serial == .[1].serial
        )
        or (
          .[0].terraform_version == "1.15.9"
          and .[1].terraform_version == "1.15.9"
          and .[0].lineage != .[1].lineage
          and .[1].serial == 1
        )
      );
    def retained_remote_metadata_matches:
      .[0].terraform_version == .[1].terraform_version
      and .[0].lineage == .[1].lineage
      and .[0].serial == .[1].serial;

    length == 2
    and all(.[]; valid_state)
    and all(.[]; has_unique_check_identities)
    and (
      (.[0] | canonical_logical_state)
      == (.[1] | canonical_logical_state)
    )
    and (
      if $metadata_contract == "post-migration" then
        post_migration_metadata_matches
      elif $metadata_contract == "retained-remote" then
        retained_remote_metadata_matches
      else
        false
      end
    )
  ' "${expected_state}" "${actual_state}" >/dev/null
}

post_migration_states_match() {
  state_equivalence_matches "$1" "$2" post-migration
}

retained_remote_state_matches() {
  state_equivalence_matches "$1" "$2" retained-remote
}

# Print present, absent or unknown for one exact object key. A truncated listing
# without the exact key cannot prove absence and is therefore unknown.
remote_key_status() {
  local object_key="$1"
  local listing

  if ! listing="$(
    aws s3api list-objects-v2 \
      --profile "${aws_profile}" \
      --bucket "${state_bucket_name}" \
      --prefix "${object_key}" \
      --no-paginate \
      --output json 2>/dev/null
  )"; then
    printf 'unknown\n'
    return
  fi

  if ! jq -e '
    type == "object"
    and (.IsTruncated | type == "boolean")
    and (.KeyCount | type == "number" and . >= 0 and floor == .)
    and ((has("Contents") | not) or (.Contents | type == "array"))
    and all(.Contents[]?; type == "object" and (.Key | type == "string"))
    and (.KeyCount == ((.Contents // []) | length))
  ' >/dev/null <<<"${listing}"; then
    printf 'unknown\n'
    return
  fi

  if jq -e --arg object_key "${object_key}" '
    [.Contents[]? | select(.Key == $object_key)] | length > 0
  ' >/dev/null <<<"${listing}"; then
    printf 'present\n'
  elif jq -e '.IsTruncated == false' >/dev/null <<<"${listing}"; then
    printf 'absent\n'
  else
    printf 'unknown\n'
  fi
}

load_active_s3_backend() {
  if [[ ! -f "${backend_file}" || -L "${backend_file}" ]] ||
    [[ "$(file_mode "${backend_file}")" != "600" ]]; then
    echo "The active backend does not match the exact S3 migration contract." >&2
    return 1
  fi

  state_bucket_name="$({
    sed -nE \
      's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' \
      "${backend_file}"
  })"
  terraform_admin_role_arn="$({
    sed -nE \
      's/^[[:space:]]*role_arn[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' \
      "${backend_file}"
  })"

  if [[ ! "${state_bucket_name}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
    [[ ! "${terraform_admin_role_arn}" =~ ^arn:[a-z0-9-]+:iam::[0-9]{12}:role/opensearch-lab-terraform-admin$ ]] ||
    ! TF_STATE_BUCKET_NAME="${state_bucket_name}" \
      TF_ADMIN_ROLE_ARN="${terraform_admin_role_arn}" \
      "${backend_contract_script}" s3-migration "${backend_file}" \
      >/dev/null 2>&1; then
    echo "The active backend does not match the exact S3 migration contract." >&2
    return 1
  fi

  if [[ ! -s "${backend_cache_file}" || ! -f "${backend_cache_file}" ||
    -L "${backend_cache_file}" ]] ||
    [[ "$(file_mode "${backend_cache_file}")" != "600" ]] ||
    ! jq -e \
      --arg state_bucket_name "${state_bucket_name}" \
      --arg state_key "${state_key}" \
      --arg aws_profile "${aws_profile}" \
      --arg terraform_admin_role_arn "${terraform_admin_role_arn}" '
        def strip_null_members:
          walk(
            if type == "object" then
              with_entries(select(.value != null))
            else
              .
            end
          );

        type == "object"
        and keys == ["backend", "terraform_version", "version"]
        and .version == 3
        and .terraform_version == "1.15.9"
        and (.backend | type) == "object"
        and (.backend | keys) == ["config", "hash", "type"]
        and .backend.type == "s3"
        and (.backend.hash | type == "number" and . >= 0 and floor == .)
        and (
          (.backend.config | strip_null_members)
          == {
            bucket: $state_bucket_name,
            key: $state_key,
            profile: $aws_profile,
            region: "eu-west-1",
            encrypt: true,
            use_lockfile: true,
            assume_role: {
              role_arn: $terraform_admin_role_arn,
              session_name: "terraform-bootstrap-state"
            }
          }
        )
      ' "${backend_cache_file}" >/dev/null; then
    echo "Terraform's cached backend metadata does not match the active S3 backend." >&2
    return 1
  fi
}

select_latest_complete_migration_pair() {
  local candidate_post
  local candidate_pre
  local candidate_name
  local candidate_run_id
  local candidate_timestamp
  local candidate_pid
  local latest_run_id=""
  local latest_timestamp=""
  local latest_pid=""

  shopt -s nullglob
  for candidate_post in "${private_dir}"/post-migration-*.tfstate; do
    candidate_name="${candidate_post##*/}"
    candidate_run_id="${candidate_name#post-migration-}"
    candidate_run_id="${candidate_run_id%.tfstate}"
    if [[ ! "${candidate_run_id}" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]; then
      continue
    fi
    candidate_timestamp="${candidate_run_id%-*}"
    candidate_pid="${candidate_run_id##*-}"

    candidate_pre="${private_dir}/pre-migration-${candidate_run_id}.tfstate"
    if [[ ! -f "${candidate_pre}" || -L "${candidate_pre}" ||
      ! -s "${candidate_pre}" || ! -f "${candidate_post}" ||
      -L "${candidate_post}" || ! -s "${candidate_post}" ]]; then
      continue
    fi

    if [[ -z "${latest_run_id}" ||
      "${candidate_timestamp}" > "${latest_timestamp}" ]] ||
      { [[ "${candidate_timestamp}" == "${latest_timestamp}" ]] &&
        ((10#${candidate_pid} > 10#${latest_pid})); }; then
      latest_run_id="${candidate_run_id}"
      latest_timestamp="${candidate_timestamp}"
      latest_pid="${candidate_pid}"
    fi
  done
  shopt -u nullglob

  if [[ -z "${latest_run_id}" ]]; then
    echo "No complete retained pre/post migration state pair is available." >&2
    return 1
  fi

  recovery_state="${private_dir}/pre-migration-${latest_run_id}.tfstate"
  retained_remote_state="${private_dir}/post-migration-${latest_run_id}.tfstate"
  if [[ "$(file_mode "${recovery_state}")" != "600" ||
    "$(file_mode "${retained_remote_state}")" != "600" ]]; then
    echo "The latest complete retained migration state pair is not mode 600." >&2
    return 1
  fi
}

verify_remote_plan_and_lock() {
  local plan_status
  local remote_lock_status

  set +e
  AWS_PROFILE="${aws_profile}" TF_VAR_terraform_admin_role_arn="${terraform_admin_role_arn}" \
    terraform -chdir="${module_dir}" plan \
    -detailed-exitcode \
    -input=false \
    -lock-timeout=60s \
    -out="${verification_plan}" \
    -refresh=false \
    -var-file="${variables_file}" \
    >/dev/null
  plan_status=$?
  set -e

  if [[ -f "${verification_plan}" ]]; then
    chmod 600 "${verification_plan}"
  fi

  case "${plan_status}" in
    0)
      ;;
    2)
      echo "The post-migration plan contains changes; migration verification failed." >&2
      return 1
      ;;
    *)
      echo "The post-migration plan could not complete." >&2
      return 1
      ;;
  esac

  remote_lock_status="$(remote_key_status "${lock_key}")"
  case "${remote_lock_status}" in
    absent)
      ;;
    present)
      echo "The post-migration plan left a Terraform state lock object behind." >&2
      return 1
      ;;
    *)
      echo "The post-migration lock object's absence could not be established." >&2
      return 1
      ;;
  esac
}

handle_failure() {
  local exit_status=$?
  local rollback_errors=0

  trap - EXIT
  set +e

  if [[ -n "${temporary_backend}" ]]; then
    if ! rm -f -- "${temporary_backend}"; then
      echo "Could not remove the temporary backend configuration." >&2
      rollback_errors=$((rollback_errors + 1))
    fi
  fi

  if [[ -n "${temporary_local_state_pull}" ]]; then
    if ! rm -f -- "${temporary_local_state_pull}"; then
      echo "Could not remove the temporary local-state snapshot." >&2
      rollback_errors=$((rollback_errors + 1))
    fi
  fi

  if [[ -n "${temporary_local_state_restore}" ]]; then
    if ! rm -f -- "${temporary_local_state_restore}"; then
      echo "Could not remove the temporary local-state restoration file." >&2
      rollback_errors=$((rollback_errors + 1))
    fi
  fi

  if [[ -n "${temporary_remote_state}" ]]; then
    if ! rm -f -- "${temporary_remote_state}"; then
      echo "Could not remove the incomplete remote-state snapshot." >&2
      rollback_errors=$((rollback_errors + 1))
    fi
  fi

  if [[ -n "${temporary_resume_remote_state}" &&
    -e "${temporary_resume_remote_state}" ]]; then
    if ! chmod 600 "${temporary_resume_remote_state}"; then
      echo "Could not secure the retained resume-verification state snapshot." >&2
      rollback_errors=$((rollback_errors + 1))
    else
      echo "The private resume-verification state snapshot was retained for recovery evidence." >&2
    fi
  fi

  case "${migration_phase}" in
    pre-write)
      if [[ "${backend_recovery_ready}" == "true" ]]; then
        if ! cp "${backend_recovery}" "${backend_file}" ||
          ! chmod "${backend_original_mode}" "${backend_file}"; then
          echo "Rollback could not restore backend.tf." >&2
          rollback_errors=$((rollback_errors + 1))
        elif ! cmp -s "${backend_recovery}" "${backend_file}"; then
          echo "Rollback restored backend.tf with different content." >&2
          rollback_errors=$((rollback_errors + 1))
        fi
      fi

      if [[ "${cache_may_have_been_mutated}" == "true" ]]; then
        if [[ "${cached_backend_should_exist}" == "true" ]]; then
          if [[ "${backend_cache_recovery_ready}" != "true" ]] ||
            ! mkdir -p "$(dirname "${backend_cache_file}")" ||
            ! cp "${backend_cache_recovery}" "${backend_cache_file}" ||
            ! chmod "${backend_cache_original_mode}" "${backend_cache_file}"; then
            echo "Rollback could not restore Terraform's cached backend metadata." >&2
            rollback_errors=$((rollback_errors + 1))
          elif ! cmp -s "${backend_cache_recovery}" "${backend_cache_file}"; then
            echo "Rollback restored Terraform's cached backend metadata with different content." >&2
            rollback_errors=$((rollback_errors + 1))
          fi
        elif ! rm -f -- "${backend_cache_file}"; then
          echo "Rollback could not remove Terraform's newly created backend metadata." >&2
          rollback_errors=$((rollback_errors + 1))
        elif [[ -e "${backend_cache_file}" ]]; then
          echo "Rollback left newly created backend metadata in place." >&2
          rollback_errors=$((rollback_errors + 1))
        fi
      fi

      if [[ "${local_state_recovery_ready}" == "true" ]]; then
        if ! temporary_local_state_restore="$(
          mktemp "${private_dir}/terraform.tfstate.rollback.XXXXXX"
        )" ||
          ! cp "${recovery_state}" "${temporary_local_state_restore}" ||
          ! chmod "${local_state_original_mode}" "${temporary_local_state_restore}" ||
          ! mv "${temporary_local_state_restore}" "${local_state_file}"; then
          echo "Rollback could not restore the original local state." >&2
          rollback_errors=$((rollback_errors + 1))
        else
          temporary_local_state_restore=""
          if ! cmp -s "${recovery_state}" "${local_state_file}"; then
            echo "Rollback restored local state which does not exactly match the recovery copy." >&2
            rollback_errors=$((rollback_errors + 1))
          fi
        fi

        if [[ -n "${temporary_local_state_restore}" ]]; then
          if ! rm -f -- "${temporary_local_state_restore}"; then
            echo "Rollback could not remove the failed local-state restoration file." >&2
            rollback_errors=$((rollback_errors + 1))
          fi
          temporary_local_state_restore=""
        fi
      fi

      if ((rollback_errors == 0)); then
        echo "Migration failed before remote state was written; the original local backend, cached metadata and state were restored and verified." >&2
      else
        printf 'Migration failed before commit and rollback was incomplete (%d rollback errors).\n' \
          "${rollback_errors}" >&2
      fi
      ;;
    partial-commit)
      echo "Terraform migration failed after a remote state or lock object was observed. The migration may be partially committed; the S3 backend and cached metadata were preserved, and local state was not reactivated." >&2
      ;;
    indeterminate)
      echo "Terraform migration failed and exact remote object absence could not be established. The migration status is indeterminate; the S3 backend and cached metadata were preserved, and local state was not reactivated." >&2
      ;;
    init-in-progress)
      remote_state_status="$(remote_key_status "${state_key}")"
      remote_lock_status="$(remote_key_status "${lock_key}")"
      if [[ "${remote_state_status}" == "present" || "${remote_lock_status}" == "present" ]]; then
        echo "Terraform migration was interrupted after a remote state or lock object was observed. The migration may be partially committed; the S3 backend and cached metadata were preserved, and local state was not reactivated." >&2
      else
        echo "Terraform migration was interrupted after init started. The migration status is indeterminate; the S3 backend and cached metadata were preserved, and local state was not reactivated." >&2
      fi
      ;;
    committed)
      echo "Migration committed to S3, but subsequent verification failed. The S3 backend remains authoritative; local state was not reactivated and the private pre-migration recovery copy was retained." >&2
      ;;
    resume-verification)
      echo "Committed migration verification failed. The S3 backend remains authoritative; no migration or local-state reactivation was attempted, and the retained pre/post migration pair was preserved." >&2
      ;;
    *)
      echo "Migration stopped in an unknown state; no automatic rollback was attempted." >&2
      rollback_errors=$((rollback_errors + 1))
      ;;
  esac

  if [[ "${lock_held}" == "true" ]]; then
    if ! rmdir "${migration_lock_dir}"; then
      echo "Could not release the state-migration invocation lock." >&2
      rollback_errors=$((rollback_errors + 1))
    fi
    lock_held=false
  fi

  if ((exit_status == 0)); then
    exit_status=1
  fi
  exit "${exit_status}"
}

trap handle_failure EXIT

if [[ "${operation}" == "resume-verification" ]]; then
  migration_phase="resume-verification"

  if [[ "$(file_mode "${private_dir}")" != "700" ]]; then
    echo "The private Terraform directory must be mode 700 for resume verification." >&2
    exit 1
  fi
  load_active_s3_backend
  select_latest_complete_migration_pair

  if ! post_migration_states_match "${recovery_state}" "${retained_remote_state}"; then
    echo "Retained post-migration state differs from the retained pre-migration state." >&2
    exit 1
  fi

  current_workspace="$(
    AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" workspace show
  )"
  workspace_names="$(
    AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" workspace list |
      sed -E 's/^[*[:space:]]+//; s/[[:space:]]+$//' |
      sed '/^$/d'
  )"
  if [[ "${current_workspace}" != "default" || "${workspace_names}" != "default" ]]; then
    echo "Committed migration verification requires default to be the only Terraform workspace." >&2
    exit 1
  fi

  temporary_resume_remote_state="$(
    mktemp "${private_dir}/resume-remote-state-pull.XXXXXX"
  )"
  if ! AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" state pull \
    >"${temporary_resume_remote_state}"; then
    echo "Current authoritative remote state could not be pulled." >&2
    exit 1
  fi
  if [[ ! -s "${temporary_resume_remote_state}" ]]; then
    echo "Current authoritative remote state pull returned an empty document." >&2
    exit 1
  fi
  chmod 600 "${temporary_resume_remote_state}"

  if ! retained_remote_state_matches \
    "${retained_remote_state}" "${temporary_resume_remote_state}"; then
    echo "Current remote state differs from the retained post-migration state." >&2
    exit 1
  fi
  if ! post_migration_states_match \
    "${recovery_state}" "${temporary_resume_remote_state}"; then
    echo "Current remote state does not satisfy the post-migration equivalence contract." >&2
    exit 1
  fi

  verify_remote_plan_and_lock

  rm -f -- "${temporary_resume_remote_state}"
  temporary_resume_remote_state=""
  if ! rmdir "${migration_lock_dir}"; then
    echo "Could not release the state-migration invocation lock." >&2
    exit 1
  fi
  lock_held=false
  trap - EXIT
  echo "Committed migration verification passed. S3 remains authoritative and the retained recovery pair was preserved."
  exit 0
fi

cp "${backend_file}" "${backend_recovery}"
chmod 600 "${backend_recovery}"
if ! cmp -s "${backend_file}" "${backend_recovery}"; then
  echo "The backend recovery copy does not exactly match backend.tf." >&2
  exit 1
fi
backend_recovery_ready=true

if [[ -e "${backend_cache_file}" ]]; then
  if [[ ! -f "${backend_cache_file}" ]]; then
    echo "Terraform's cached backend metadata is not a regular file." >&2
    exit 1
  fi
  backend_cache_original_mode="$(file_mode "${backend_cache_file}")"
  cp "${backend_cache_file}" "${backend_cache_recovery}"
  chmod 600 "${backend_cache_recovery}"
  if ! cmp -s "${backend_cache_file}" "${backend_cache_recovery}"; then
    echo "The backend-cache recovery copy does not exactly match the original." >&2
    exit 1
  fi
  cached_backend_should_exist=true
  backend_cache_recovery_ready=true
fi

cp "${local_state_file}" "${recovery_state}"
chmod 600 "${recovery_state}"
if ! cmp -s "${local_state_file}" "${recovery_state}"; then
  echo "The local-state recovery copy does not exactly match the original." >&2
  exit 1
fi
local_state_recovery_ready=true

cache_may_have_been_mutated=true
AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" init -reconfigure -input=false >/dev/null

if [[ ! -s "${backend_cache_file}" ]]; then
  echo "Terraform did not materialise cached local-backend metadata." >&2
  exit 1
fi

current_workspace="$(AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" workspace show)"
workspace_names="$(
  AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" workspace list |
    sed -E 's/^[*[:space:]]+//; s/[[:space:]]+$//' |
    sed '/^$/d'
)"

if [[ "${current_workspace}" != "default" || "${workspace_names}" != "default" ]]; then
  echo "State migration requires default to be the only Terraform workspace." >&2
  exit 1
fi

temporary_local_state_pull="$(mktemp "${private_dir}/local-state-pull.XXXXXX")"
AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" state pull >"${temporary_local_state_pull}"
chmod 600 "${temporary_local_state_pull}"

if [[ ! -s "${temporary_local_state_pull}" ]] ||
  ! cmp -s "${local_state_file}" "${recovery_state}" ||
  ! states_match "${recovery_state}" "${temporary_local_state_pull}"; then
  echo "The original local state does not match its exact recovery copy and pulled snapshot." >&2
  exit 1
fi
rm -f -- "${temporary_local_state_pull}"
temporary_local_state_pull=""

state_bucket_name="$(AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" output -raw state_bucket_name)"
if [[ ! "${state_bucket_name}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  echo "The state bucket output is not a valid S3 bucket name." >&2
  exit 1
fi

terraform_admin_role_arn="$(AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" output -raw terraform_admin_role_arn)"
if [[ ! "${terraform_admin_role_arn}" =~ ^arn:[a-z0-9-]+:iam::[0-9]{12}:role/opensearch-lab-terraform-admin$ ]]; then
  echo "The Terraform administration role output is not the expected role ARN." >&2
  exit 1
fi

temporary_backend="$(mktemp "${private_dir}/backend.tf.XXXXXX")"

cat >"${temporary_backend}" <<EOF
terraform {
  backend "s3" {
    bucket       = "${state_bucket_name}"
    key          = "${state_key}"
    profile      = "${aws_profile}"
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

TF_STATE_BUCKET_NAME="${state_bucket_name}" \
  TF_ADMIN_ROLE_ARN="${terraform_admin_role_arn}" \
  "${backend_contract_script}" s3-migration "${temporary_backend}" >/dev/null

remote_state_status="$(remote_key_status "${state_key}")"
remote_lock_status="$(remote_key_status "${lock_key}")"

if [[ "${remote_state_status}" == "present" || "${remote_lock_status}" == "present" ]]; then
  echo "The remote state destination is not empty; no migration was attempted." >&2
  exit 1
fi
if [[ "${remote_state_status}" != "absent" || "${remote_lock_status}" != "absent" ]]; then
  echo "The remote state destination could not be proven empty; no migration was attempted." >&2
  exit 1
fi

mv "${temporary_backend}" "${backend_file}"
temporary_backend=""
chmod 600 "${backend_file}"

migration_phase="init-in-progress"
init_interrupted=false
record_init_interruption() {
  init_interrupted=true
}
trap record_init_interruption HUP INT TERM
set +e
AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" init -migrate-state -force-copy -input=false
init_status=$?
set -e
trap - HUP INT TERM

if [[ "${init_interrupted}" == "true" ]]; then
  if ((init_status == 0)); then
    init_status=1
  fi
  exit "${init_status}"
elif ((init_status == 0)); then
  # Successful init is the commit point. Every later failure must leave the S3
  # backend and its cached metadata active.
  migration_phase="committed"
else
  remote_state_status="$(remote_key_status "${state_key}")"
  remote_lock_status="$(remote_key_status "${lock_key}")"

  if [[ "${remote_state_status}" == "absent" && "${remote_lock_status}" == "absent" ]]; then
    migration_phase="pre-write"
    echo "Terraform state migration failed, but both exact remote keys are absent; safe rollback is permitted." >&2
  elif [[ "${remote_state_status}" == "present" || "${remote_lock_status}" == "present" ]]; then
    migration_phase="partial-commit"
  else
    migration_phase="indeterminate"
  fi
  exit "${init_status}"
fi

temporary_remote_state="$(mktemp "${private_dir}/remote-state-pull.XXXXXX")"
if ! AWS_PROFILE="${aws_profile}" terraform -chdir="${module_dir}" state pull >"${temporary_remote_state}"; then
  echo "Remote state could not be pulled after migration committed." >&2
  exit 1
fi
if [[ ! -s "${temporary_remote_state}" ]]; then
  echo "Remote state pull returned an empty document after migration committed." >&2
  exit 1
fi
chmod 600 "${temporary_remote_state}"
mv "${temporary_remote_state}" "${remote_state}"
temporary_remote_state=""

if ! post_migration_states_match "${recovery_state}" "${remote_state}"; then
  echo "Remote state differs from the recovered local state." >&2
  exit 1
fi

verify_remote_plan_and_lock

if ! rmdir "${migration_lock_dir}"; then
  echo "Could not release the state-migration invocation lock." >&2
  exit 1
fi
lock_held=false
trap - EXIT
echo "Remote state and native locking were verified. S3 is authoritative and the private recovery copy was retained."
