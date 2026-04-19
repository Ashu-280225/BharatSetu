#!/usr/bin/env bash
# BharatSetu — First-time setup script
# Usage: bash setup.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

ok()    { echo -e "  ${GREEN}✓${RESET}  $*"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
info()  { echo -e "  ${CYAN}→${RESET}  $*"; }
fail()  { echo -e "  ${RED}✗${RESET}  $*\n"; exit 1; }
sep()   { echo -e "${DIM}────────────────────────────────────────────────────${RESET}"; }
header(){ echo -e "\n${BOLD}[$1] $2${RESET}"; }

echo ""
echo -e "${BOLD}${CYAN}  BharatSetu — Setup${RESET}"
sep

# ── OS selection ──────────────────────────────────────────────────────────────
AUTO_OS="$(uname -s)"
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then IS_WSL=true; fi

echo ""
echo -e "  ${BOLD}Select your operating system:${RESET}"
echo ""
echo -e "    ${CYAN}1)${RESET} macOS"
echo -e "    ${CYAN}2)${RESET} Linux  ${DIM}(Ubuntu / Debian)${RESET}"
echo -e "    ${CYAN}3)${RESET} Windows  ${DIM}(WSL2 recommended)${RESET}"
echo ""

# Pre-select based on auto-detection
if [[ "$AUTO_OS" == "Darwin" ]]; then
  DEFAULT=1
elif $IS_WSL; then
  DEFAULT=3
else
  DEFAULT=2
fi

read -rp "  Enter choice [default: $DEFAULT]: " OS_CHOICE
OS_CHOICE="${OS_CHOICE:-$DEFAULT}"

case "$OS_CHOICE" in
  1) PLATFORM="macos"   ;;
  2) PLATFORM="linux"   ;;
  3) PLATFORM="windows" ;;
  *)
    fail "Invalid choice '$OS_CHOICE'. Run again and enter 1, 2, or 3."
    ;;
esac

echo ""
ok "Platform: $PLATFORM"

# ── Windows — hand off to WSL ─────────────────────────────────────────────────
if [[ "$PLATFORM" == "windows" ]]; then
  echo ""
  if $IS_WSL; then
    # Already running inside WSL — treat as Linux
    warn "Detected WSL environment. Continuing as Linux..."
    PLATFORM="linux"
  else
    # Running in Git Bash / MINGW / native Windows bash — can't proceed
    sep
    echo -e "\n  ${BOLD}Windows Setup Instructions${RESET}\n"
    echo -e "  Bash scripts can't install system tools on native Windows."
    echo -e "  We provide a PowerShell script that sets up WSL2 + Ubuntu"
    echo -e "  and then runs this setup automatically inside it.\n"
    echo -e "  ${BOLD}Step 1${RESET} — Open ${BOLD}PowerShell as Administrator${RESET} and run:"
    echo ""
    echo -e "    ${CYAN}Set-ExecutionPolicy RemoteSigned -Scope CurrentUser${RESET}"
    echo -e "    ${CYAN}cd path\\to\\BharatSetu${RESET}"
    echo -e "    ${CYAN}.\\setup_windows.ps1${RESET}"
    echo ""
    echo -e "  ${BOLD}Step 2${RESET} — After WSL installs and reboots, open ${BOLD}Ubuntu${RESET} from Start Menu"
    echo -e "           and run: ${CYAN}bash setup.sh${RESET} inside the repo directory."
    echo ""
    echo -e "  ${DIM}Already have WSL2 + Ubuntu? Just open Ubuntu terminal, navigate"
    echo -e "  to the repo (e.g. /mnt/c/Users/you/BharatSetu) and run:${RESET}"
    echo -e "    ${CYAN}bash setup.sh${RESET}"
    echo ""
    sep
    exit 0
  fi
fi

# ── Validate we're on the right shell for the chosen platform ─────────────────
if [[ "$PLATFORM" == "macos" && "$AUTO_OS" != "Darwin" ]]; then
  fail "You selected macOS but this machine is running $AUTO_OS. Re-run and pick the correct OS."
fi
if [[ "$PLATFORM" == "linux" && "$AUTO_OS" == "Darwin" ]]; then
  fail "You selected Linux but this machine is macOS. Re-run and pick macOS."
fi

# ── 1. Package Manager ────────────────────────────────────────────────────────
header "1/8" "Package Manager"

if [[ "$PLATFORM" == "macos" ]]; then
  if command -v brew &>/dev/null; then
    ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"
  else
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    ok "Homebrew installed"
  fi
else
  if command -v apt-get &>/dev/null; then
    ok "apt-get available"
    info "Updating package lists..."
    sudo apt-get update -qq
  else
    fail "apt-get not found. This script supports Ubuntu/Debian.\nOn other distros install Elixir, Node.js 18+, PostgreSQL 14+ manually then re-run."
  fi
fi

# ── 2. Elixir + Erlang ────────────────────────────────────────────────────────
header "2/8" "Elixir & Erlang"

if command -v elixir &>/dev/null; then
  ELIXIR_VSN=$(elixir --version 2>/dev/null | grep "Elixir" | awk '{print $2}')
  ok "Elixir $ELIXIR_VSN"
else
  info "Installing Elixir (includes Erlang/OTP)..."
  if [[ "$PLATFORM" == "macos" ]]; then
    brew install elixir
  else
    wget -qO /tmp/erlang-solutions.deb https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
    sudo dpkg -i /tmp/erlang-solutions.deb
    sudo apt-get update -qq
    sudo apt-get install -y esl-erlang elixir
  fi
  ok "Elixir installed"
fi

# ── 3. Node.js ────────────────────────────────────────────────────────────────
header "3/8" "Node.js"

if command -v node &>/dev/null; then
  NODE_VSN=$(node --version)
  MAJOR="${NODE_VSN#v}"; MAJOR="${MAJOR%%.*}"
  if [[ "$MAJOR" -lt 18 ]]; then
    warn "Node.js $NODE_VSN is too old (need v18+). Upgrading..."
    if [[ "$PLATFORM" == "macos" ]]; then
      brew upgrade node || brew install node
    else
      curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
      sudo apt-get install -y nodejs
    fi
    ok "Node.js upgraded to $(node --version)"
  else
    ok "Node.js $NODE_VSN"
  fi
else
  info "Installing Node.js 20..."
  if [[ "$PLATFORM" == "macos" ]]; then
    brew install node
  else
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
  fi
  ok "Node.js $(node --version) installed"
fi

# ── 4. PostgreSQL ─────────────────────────────────────────────────────────────
header "4/8" "PostgreSQL"

if command -v psql &>/dev/null; then
  ok "PostgreSQL $(psql --version | awk '{print $3}')"
else
  info "Installing PostgreSQL 16..."
  if [[ "$PLATFORM" == "macos" ]]; then
    brew install postgresql@16
    brew link postgresql@16 --force
  else
    sudo apt-get install -y postgresql postgresql-contrib
  fi
  ok "PostgreSQL installed"
fi

# Start PostgreSQL
if [[ "$PLATFORM" == "macos" ]]; then
  if ! lsof -iTCP:5432 -sTCP:LISTEN -t &>/dev/null; then
    info "Starting PostgreSQL..."
    brew services start postgresql@16 2>/dev/null || brew services start postgresql 2>/dev/null
    sleep 3
  fi
else
  if ! pg_isready -q 2>/dev/null; then
    info "Starting PostgreSQL service..."
    sudo service postgresql start
    sleep 2
  fi
fi

if lsof -iTCP:5432 -sTCP:LISTEN -t &>/dev/null || pg_isready -q 2>/dev/null; then
  ok "PostgreSQL running on :5432"
else
  fail "PostgreSQL failed to start."
fi

# Ensure 'postgres' superuser exists (required by Ecto)
info "Ensuring 'postgres' DB user exists..."
if [[ "$PLATFORM" == "macos" ]]; then
  psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='postgres'" 2>/dev/null | grep -q 1 \
    || createuser -s postgres 2>/dev/null || true
else
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='postgres'" | grep -q 1 \
    || sudo -u postgres createuser -s postgres 2>/dev/null || true
  sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';" 2>/dev/null || true
fi
ok "postgres user ready"

# ── 5. Hex + Rebar ────────────────────────────────────────────────────────────
header "5/8" "Elixir Package Managers"

cd "$ROOT"
mix local.hex --force --if-missing 2>/dev/null && ok "Hex ready"
mix local.rebar --force 2>/dev/null             && ok "Rebar3 ready"

# ── 6. Mix dependencies ───────────────────────────────────────────────────────
header "6/8" "Elixir Dependencies"

info "Fetching mix deps (first run may take a few minutes)..."
MIX_ENV=dev mix deps.get 2>&1 | tail -5
ok "mix deps ready"

# ── 7. Database ───────────────────────────────────────────────────────────────
header "7/8" "Database"

info "Creating database..."
MIX_ENV=dev mix ecto.create 2>&1 | grep -E "created|already|error" || true
ok "Database ready"

info "Running migrations..."
MIX_ENV=dev mix ecto.migrate 2>&1 | tail -5
ok "Migrations done"

# ── 8. Frontend dependencies ──────────────────────────────────────────────────
header "8/8" "Frontend Dependencies"

info "Installing npm packages..."
cd "$ROOT/frontend"
npm install --silent 2>&1 | tail -3
ok "npm packages ready"

# ── Hand off to dev.sh ────────────────────────────────────────────────────────
echo ""
sep
echo -e "${BOLD}${GREEN}  Setup complete! Starting dev environment…${RESET}"
sep
echo ""

cd "$ROOT"
bash dev.sh
