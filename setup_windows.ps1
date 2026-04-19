# BharatSetu — Windows Setup Script
# Run as Administrator in PowerShell:
#   Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#   .\setup_windows.ps1

$ErrorActionPreference = "Stop"

function Write-OK    { param($msg) Write-Host "  [OK] $msg"   -ForegroundColor Green  }
function Write-Info  { param($msg) Write-Host "  --> $msg"    -ForegroundColor Cyan   }
function Write-Warn  { param($msg) Write-Host "  [!] $msg"    -ForegroundColor Yellow }
function Write-Fail  { param($msg) Write-Host "  [X] $msg`n"  -ForegroundColor Red; exit 1 }
function Write-Sep   { Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "  BharatSetu — Windows Setup" -ForegroundColor Cyan
Write-Sep

# ── Check Administrator ────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
  Write-Fail "Please run PowerShell as Administrator (right-click → Run as administrator)."
}
Write-OK "Running as Administrator"

# ── Check Windows version (WSL2 needs Win10 2004+ / Win11) ────────────────────
$winVer = [System.Environment]::OSVersion.Version
if ($winVer.Major -lt 10 -or ($winVer.Major -eq 10 -and $winVer.Build -lt 19041)) {
  Write-Fail "WSL2 requires Windows 10 version 2004 (build 19041) or later. Your build: $($winVer.Build). Please update Windows first."
}
Write-OK "Windows version OK (build $($winVer.Build))"

# ── Check / Install WSL2 ──────────────────────────────────────────────────────
Write-Host "`n  [1/3] WSL2" -ForegroundColor White

$wslStatus = wsl --status 2>$null
if ($LASTEXITCODE -eq 0 -and $wslStatus -match "Default Version: 2") {
  Write-OK "WSL2 already installed"
} else {
  Write-Info "Installing WSL2 with Ubuntu (this will require a restart)..."
  Write-Host ""
  Write-Host "  WSL2 installation will begin. After your machine restarts," -ForegroundColor Yellow
  Write-Host "  open 'Ubuntu' from the Start Menu, complete the Linux user setup," -ForegroundColor Yellow
  Write-Host "  then run this inside Ubuntu:" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "    cd /mnt/c/<path-to-BharatSetu>" -ForegroundColor Cyan
  Write-Host "    bash setup.sh" -ForegroundColor Cyan
  Write-Host ""
  Read-Host "  Press Enter to install WSL2 and restart, or Ctrl+C to cancel"

  wsl --install -d Ubuntu
  Write-Warn "Restart required. After restart, open Ubuntu from Start Menu and run: bash setup.sh"
  Read-Host "Press Enter to restart now, or Ctrl+C to restart manually later"
  Restart-Computer -Force
}

# ── Check Ubuntu distro is installed ─────────────────────────────────────────
Write-Host "`n  [2/3] Ubuntu" -ForegroundColor White

$distros = wsl --list --quiet 2>$null
if ($distros -notmatch "Ubuntu") {
  Write-Info "Installing Ubuntu in WSL2..."
  wsl --install -d Ubuntu
  Write-Warn "Ubuntu installed. Open Ubuntu from Start Menu, set up your Linux user, then run:"
  Write-Host "    bash setup.sh" -ForegroundColor Cyan
  exit 0
}
Write-OK "Ubuntu distro available"

# ── Run setup.sh inside WSL ───────────────────────────────────────────────────
Write-Host "`n  [3/3] Running setup.sh inside WSL Ubuntu" -ForegroundColor White

# Convert Windows path to WSL path
$repoPath = (Get-Location).Path
$wslPath   = "/mnt/" + ($repoPath -replace "\\", "/" -replace ":", "").ToLower()

Write-Info "Repo path in WSL: $wslPath"
Write-Info "Starting setup (this will take a few minutes)..."
Write-Host ""

wsl -d Ubuntu -- bash -c "cd '$wslPath' && bash setup.sh"

if ($LASTEXITCODE -ne 0) {
  Write-Fail "setup.sh failed inside WSL. Check the output above for errors."
}

Write-Host ""
Write-Sep
Write-OK "All done! BharatSetu is running inside WSL."
Write-Host ""
Write-Host "  Access the app at: http://localhost:3000" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To restart later, open Ubuntu from Start Menu and run:" -ForegroundColor DarkGray
Write-Host "    cd $wslPath && bash dev.sh" -ForegroundColor Cyan
Write-Host ""
Write-Sep
