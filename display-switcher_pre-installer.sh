#!/usr/bin/env bash
# -*- mode: shell-script -*-
# Environment Bootstrap & Pre-Flight Installer for Display-Switcher

OSTYPE=$(uname -s)
ARCH=$(uname -m | tr '[:lower:]' '[:upper:]')
[[ "$OSTYPE" == *"MINGW"* || "$OSTYPE" == *"MSYS"* || "$OSTYPE" == *"CYGWIN"* || "$OSTYPE" == *"NT"* ]] && OSTYPE="Win"

[[ -z $RED ]] && source .ansi 2>/dev/null || true
[[ -z "$(which mytools)" ]] && echo "ERROR: mytools not found. Must be installed." && exit 1

LOG_FILE="$HOME/Desktop/display-switcher_bootstrap.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo "==> Environment Bootstrap Started: $(date)"
echo "=================================================="

# ==========================================
# 1. CHECK & INSTALL DISPLAY CONTROL TOOLS
# ==========================================
echo "==> Checking display control tools..."

if [[ "$OSTYPE" == "Linux" ]]; then
    REQUIRED_TOOL="ddcutil"
    RESOLVED_TOOL=$(sh -c 'export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"; which ddcutil' 2>/dev/null || true)
    
    if [[ -z "$RESOLVED_TOOL" ]]; then
        echo "--> Missing [$REQUIRED_TOOL]. Installing via system package manager..."
        if ! sudo -v; then
            echo "ERROR: sudo authentication failed or cancelled." >&2
            exit 1
        fi
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y ddcutil
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y ddcutil
        elif command -v pacman &>/dev/null; then
            sudo pacman -S --noconfirm ddcutil
        elif command -v zypper &>/dev/null; then
            sudo zypper install -y ddcutil
        else
            echo "ERROR: No supported package manager found to install $REQUIRED_TOOL." >&2
            exit 1
        fi
    else
        echo "==> Found [$REQUIRED_TOOL] at: $RESOLVED_TOOL"
    fi

elif [[ "$OSTYPE" == "Darwin" ]]; then
    REQUIRED_TOOL="ddcctl"
    RESOLVED_TOOL=$(sh -c 'export PATH="/opt/local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"; which ddcctl' 2>/dev/null || true)
    
    if [[ -z "$RESOLVED_TOOL" ]]; then
        echo "--> Missing [$REQUIRED_TOOL]. Installing via MacPorts or Homebrew..."
        if command -v port &>/dev/null; then
            sudo port -v selfupdate || true
            sudo port -v install ddcctl
        elif command -v brew &>/dev/null; then
            brew install ddcctl
        else
            echo "ERROR: Neither MacPorts (port) nor Homebrew (brew) found. Please install one first." >&2
            exit 1
        fi
    else
        echo "==> Found [$REQUIRED_TOOL] at: $RESOLVED_TOOL"
    fi

else
    REQUIRED_TOOL="ControlMyMonitor.exe"
    RESOLVED_TOOL=$(which "$REQUIRED_TOOL" 2>/dev/null || true)
    if [[ -z "$RESOLVED_TOOL" ]]; then
        echo "--> Downloading $REQUIRED_TOOL for Windows..."
        powershell.exe -Command "
            \$dir = [Environment]::GetFolderPath('LocalApplicationData') + '\\Programs\\Display Switcher';
            New-Item -ItemType Directory -Force -Path \$dir | Out-Null;
            \$zip = Join-Path \$dir 'controlmymonitor.zip';
            try {
                Invoke-WebRequest -Uri 'https://www.nirsoft.net/utils/controlmymonitor.zip' -OutFile \$zip;
                Expand-Archive -Force \$zip \$dir;
                Remove-Item \$zip;
            } catch {
                Write-Error 'Failed to download ControlMyMonitor: \$(\$_.Exception.Message)';
                exit 1;
            }
        "
    else
        echo "==> Found [$REQUIRED_TOOL] at: $RESOLVED_TOOL"
    fi
fi

# ==========================================
# 2. CHECK & INSTALL RUST TOOLCHAIN (CARGO)
# ==========================================
echo "==> Checking Rust toolchain..."
RESOLVED_CARGO=$(sh -c 'export PATH="/opt/local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.cargo/bin:$PATH"; which cargo' 2>/dev/null || true)

if [[ -z "$RESOLVED_CARGO" ]]; then
    echo "--> Missing [cargo]. Installing Rust via rustup..."
    if ! command -v curl &>/dev/null; then
        echo "ERROR: 'curl' is required to install Rust." >&2
        exit 1
    fi
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
else
    echo "==> Found [cargo] at: $RESOLVED_CARGO"
fi

# ==========================================
# 3. CHECK & INSTALL BUILD ESSENTIALS / XCODE CLT
# ==========================================
echo "==> Checking build tools & compilers..."

if [[ "$OSTYPE" == "Darwin" ]]; then
    if ! xcode-select -p &>/dev/null; then
        echo "--> Missing Xcode Command Line Tools. Requesting installation..."
        xcode-select --install || true
        echo "Please complete the Xcode Command Line Tools GUI prompt, then re-run this bootstrap."
        exit 1
    else
        echo "==> Found Xcode CLT at: $(xcode-select -p)"
    fi
elif [[ "$OSTYPE" == "Linux" ]]; then
    if ! command -v cc &>/dev/null && ! command -v gcc &>/dev/null; then
        echo "--> Missing C compiler. Installing build-essentials..."
        if ! sudo -v; then
            echo "ERROR: sudo authentication failed or cancelled." >&2
            exit 1
        fi
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y build-essential
        elif command -v dnf &>/dev/null; then
            sudo dnf groupinstall -y "Development Tools"
        elif command -v pacman &>/dev/null; then
            sudo pacman -S --noconfirm base-devel
        fi
    else
        echo "==> Found build compiler."
    fi
fi

echo "=================================================="
echo "==> Environment Bootstrap Completed Successfully!"
echo "You can now run your display-switcher app installer."
echo "=================================================="
# <LAST_SAVED> 20261012 00:18:18
