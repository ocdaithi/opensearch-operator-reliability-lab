#!/usr/bin/env bash

set -euo pipefail

if (($# != 1)); then
  echo "Usage: policy-contract-digest.sh <policy.json>" >&2
  exit 1
fi

policy_file="$1"
if [[ ! -f "${policy_file}" ]]; then
  echo "The policy document is missing." >&2
  exit 1
fi

canonical_policy="$(jq -Sc '
  def canonical:
    if type == "object" then
      to_entries | sort_by(.key) | map(.value |= canonical) | from_entries
    elif type == "array" then
      map(canonical) | sort_by(tojson)
    else
      .
    end;
  canonical
' "${policy_file}")"

if command -v sha256sum >/dev/null 2>&1; then
  digest_line="$(printf '%s\n' "${canonical_policy}" | sha256sum)"
elif command -v shasum >/dev/null 2>&1; then
  digest_line="$(printf '%s\n' "${canonical_policy}" | shasum -a 256)"
else
  echo "Required SHA-256 command is unavailable: sha256sum or shasum" >&2
  exit 1
fi

printf '%s\n' "${digest_line%% *}"
