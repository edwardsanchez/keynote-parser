#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python_bin="${repo_root}/.venv/bin/python"

if [[ ! -x "${python_bin}" ]]; then
  echo "Missing virtualenv at ${repo_root}/.venv" >&2
  echo "Run: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2
  exit 1
fi

if [[ -n "${PYTHONWARNINGS:-}" ]]; then
  export PYTHONWARNINGS="ignore:KeynoteVersionWarning,${PYTHONWARNINGS}"
else
  export PYTHONWARNINGS="ignore:KeynoteVersionWarning"
fi

exec "${python_bin}" -m keynote_parser.command_line "$@"
