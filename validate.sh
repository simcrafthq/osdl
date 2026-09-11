#!/usr/bin/env bash
# Validate all OSDL specification artifacts.
set -euo pipefail
cd "$(dirname "$0")"
repository_root="$(pwd -P)"

npm ci
OSDL_SKIP_SELF_TEST=1 npm test
echo "Node contract tests pass."

node scripts/validate-osdl.mjs examples/*.osdl.json
echo "OSDL documents and libraries are valid."

# The reference machine (Lean 4) must build when a toolchain is available.
if command -v lake >/dev/null 2>&1 || [ -x "$HOME/.elan/bin/lake" ]; then
  (cd machine && PATH="$HOME/.elan/bin:$PATH" lake build)
  echo "Reference machine builds."

  (cd machine && PATH="$HOME/.elan/bin:$PATH" lake exe preparationcheck)
  echo "Preparation checks pass."

  (cd machine && PATH="$HOME/.elan/bin:$PATH" lake exe vectorroundtripcheck)
  echo "Vector round-trip checks pass."

  (cd machine && PATH="$HOME/.elan/bin:$PATH" lake exe cataloguecheck)
  echo "Conformance catalogue is valid."

  conformance_tmp="$(mktemp -d "${TMPDIR:-/tmp}/osdl-conformance.XXXXXX")"
  if [ -z "$conformance_tmp" ] || [ ! -d "$conformance_tmp" ] || [ -L "$conformance_tmp" ]; then
    echo "invalid conformance temporary directory: $conformance_tmp" >&2
    exit 1
  fi
  conformance_tmp="$(cd "$conformance_tmp" && pwd -P)"
  case "$conformance_tmp" in
    "$repository_root"|"$repository_root"/*)
      echo "conformance temporary directory is inside the repository: $conformance_tmp" >&2
      exit 1
      ;;
  esac
  case "$(basename "$conformance_tmp")" in
    osdl-conformance.*) ;;
    *)
      echo "unexpected conformance temporary directory: $conformance_tmp" >&2
      exit 1
      ;;
  esac

  cleanup_conformance_tmp() {
    if [ -z "${conformance_tmp:-}" ] || [ ! -d "$conformance_tmp" ] || [ -L "$conformance_tmp" ]; then
      echo "refusing to remove invalid conformance temporary directory: ${conformance_tmp:-<empty>}" >&2
      return 1
    fi
    case "$conformance_tmp" in
      "$repository_root"|"$repository_root"/*)
        echo "refusing to remove repository path: $conformance_tmp" >&2
        return 1
        ;;
    esac
    case "$(basename "$conformance_tmp")" in
      osdl-conformance.*) ;;
      *)
        echo "refusing to remove unexpected path: $conformance_tmp" >&2
        return 1
        ;;
    esac
    rm -rf -- "$conformance_tmp"
  }
  trap cleanup_conformance_tmp EXIT

  node scripts/update-conformance.mjs --output "$conformance_tmp"
  conformance_artifact_list="$(node scripts/update-conformance.mjs --list)"
  if [ -z "$conformance_artifact_list" ]; then
    echo "generated conformance artifact list is empty" >&2
    exit 1
  fi
  if ! diff -u \
      <(printf '%s\n' "$conformance_artifact_list") \
      <((cd "$conformance_tmp" && find . -type f -print | sed 's|^\./||' | LC_ALL=C sort)); then
    echo "generated conformance artifact file set differs from committed artifacts" >&2
    exit 1
  fi
  while IFS= read -r artifact_path; do
    if ! cmp -s "$conformance_tmp/$artifact_path" "$artifact_path"; then
      echo "generated conformance artifact differs from $artifact_path" >&2
      exit 1
    fi
  done <<< "$conformance_artifact_list"
  artifact_count="$(printf '%s\n' "$conformance_artifact_list" | wc -l | tr -d ' ')"
  echo "Conformance artifacts match committed files ($artifact_count files)."

  vectors_tmp="$conformance_tmp/golden-vectors.txt"
  (cd machine && PATH="$HOME/.elan/bin:$PATH" lake exe genvectors) > "$vectors_tmp"
  if ! cmp -s "$vectors_tmp" machine/vectors/golden.txt; then
    echo "generated golden vectors differ from machine/vectors/golden.txt" >&2
    exit 1
  fi
  echo "Golden vectors match committed file."

  (cd machine && PATH="$HOME/.elan/bin:$PATH" lake exe vectors)
  echo "Golden vector checks pass."

  (cd machine && PATH="$HOME/.elan/bin:$PATH" lake exe roundcheck)
  echo "Resolution-round checks pass."

  (cd machine && PATH="$HOME/.elan/bin:$PATH" lake exe runcontrolcheck)
  echo "Run-control checks pass."

  (cd machine && PATH="$HOME/.elan/bin:$PATH" lake exe transfercheck)
  echo "Transfer custody checks pass."

  (cd machine && PATH="$HOME/.elan/bin:$PATH" lake exe safeguardcheck)
  echo "Safeguard checks pass."

elif [ "${OSDL_REQUIRE_LEAN:-0}" = "1" ]; then
  echo "lake not found; OSDL_REQUIRE_LEAN=1 requires Lean 4 via elan." >&2
  exit 1
else
  echo "lake not found; skipping reference-machine build (install elan to enable)."
fi

echo "All OSDL specification artifacts are valid."
