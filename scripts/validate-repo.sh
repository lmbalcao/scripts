#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

required_files=(
  README.md
  CHANGELOG.md
  AGENTS.md
  CONTRIBUTING.md
  SECURITY.md
  CODEOWNERS
  .editorconfig
  .gitattributes
  .gitignore
  .claude/settings.json
  .forgejo/workflows/validate.yml
  .forgejo/pull_request_template.md
  .forgejo/ISSUE_TEMPLATE/bug.yml
  .forgejo/ISSUE_TEMPLATE/feature.yml
  .forgejo/ISSUE_TEMPLATE/config.yml
  scripts/update-changelog.py
)

for path in "${required_files[@]}"; do
  if [[ ! -e "$path" ]]; then
    echo "Missing required file: $path" >&2
    exit 1
  fi
done

if [[ -f .forgejo/workflows/release.yml && ! -f VERSION ]]; then
  echo "Missing VERSION for release-enabled repository" >&2
  exit 1
fi

if [[ -f VERSION ]]; then
  python3 - <<'PYCODE'
import re
from pathlib import Path
line = Path('VERSION').read_text(encoding='utf-8').splitlines()[0].strip()
if not re.fullmatch(r'\d+\.\d+\.\d+', line):
    raise SystemExit('VERSION first line must be semantic version X.Y.Z')
PYCODE
fi

mapfile -t shell_files < <(find .claude .codex scripts -type f -name '*.sh' | sort)
if (( ${#shell_files[@]} > 0 )); then
  bash -n "${shell_files[@]}"
fi

mapfile -t python_files < <(find scripts -type f -name '*.py' | sort)
if (( ${#python_files[@]} > 0 )); then
  python3 -m py_compile "${python_files[@]}"
fi

python3 -m json.tool .claude/settings.json >/dev/null

echo "Repository baseline validation passed."
