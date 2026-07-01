# Run the git-monitor.nvim test suite (Windows / PowerShell).
# Usage:  powershell -File tests\run.ps1
# Exits 0 if all tests pass, non-zero otherwise.
$ErrorActionPreference = "Continue"
Set-Location (Join-Path $PSScriptRoot "..")
& nvim --headless -u tests/minimal_init.lua -c "luafile tests/gitmonitor_spec.lua"
$code = $LASTEXITCODE
Write-Host ""
if ($code -eq 0) { Write-Host "ALL TESTS PASSED" } else { Write-Host "TESTS FAILED (exit $code)" }
exit $code
