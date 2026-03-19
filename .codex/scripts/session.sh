#!/usr/bin/env bash
set -euo pipefail

artifacts_root=".claude/artifacts"
current_file="$artifacts_root/current.txt"
current_link="$artifacts_root/current"

resolve_session_ref() {
  local ref="${1:-}"

  case "$ref" in
    "")
      return 1
      ;;
    /*|.claude/artifacts/*)
      printf '%s\n' "$ref"
      ;;
    *)
      printf '%s/%s\n' "$artifacts_root" "$ref"
      ;;
  esac
}

mkdir -p "$artifacts_root"

command_name="${1:-new}"
case "$command_name" in
  new)
    task_slug="${2:-task}"
    safe_slug="$(echo "$task_slug" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//' | cut -c1-40)"
    ts="$(date +%Y%m%d-%H%M%S)"
    session_dir="$artifacts_root/$ts-${safe_slug:-task}"
    mkdir -p "$session_dir"
    printf '%s\n' "$session_dir" > "$current_file"
    ln -sfn "$(basename "$session_dir")" "$current_link"
    echo "$session_dir"
    ;;
  current)
    if [[ -f "$current_file" ]]; then
      resolve_session_ref "$(tr -d '\n' < "$current_file")"
    else
      echo "No current session. Run: $0 new <task>" >&2
      exit 1
    fi
    ;;
  *)
    echo "Usage: $0 {new <task>|current}" >&2
    exit 2
    ;;
esac
