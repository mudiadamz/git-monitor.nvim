#!/usr/bin/env bash
# Run the git-monitor.nvim test suite. Usage: bash tests/run.sh
# Exits 0 if all tests pass, non-zero otherwise.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
nvim --headless -u tests/minimal_init.lua -c "luafile tests/gitmonitor_spec.lua"
code=$?
echo
if [ "$code" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "TESTS FAILED (exit $code)"; fi
exit "$code"
