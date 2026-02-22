#!/usr/bin/env bash
#
# build-interactive.sh — Interactive wrapper for building the MacBook K8s ISO on macOS
#
# Installs required tools, walks through configuration, then runs build-iso.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="${SCRIPT_DIR}/build-iso.sh"

# ── Colors & helpers ──────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()    { echo -e "${CYAN}▸${RESET} $*"; }
success() { echo -e "${GREEN}✔${RESET} $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET} $*"; }
err()     { echo -e "${RED}✖${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}$*${RESET}"; echo -e "${DIM}$(printf '─%.0s' $(seq 1 ${#1}))${RESET}"; }

# Prompt with default value: ask "Prompt text" DEFAULT_VALUE
ask() {
    local prompt="$1" default="$2" reply
    if [[ -n "$default" ]]; then
        echo -en "  ${prompt} ${DIM}[${default}]${RESET}: " >&2
    else
        echo -en "  ${prompt}: " >&2
    fi
    read -r reply
    echo "${reply:-$default}"
}

# Prompt for password (hidden input)
ask_password() {
    local prompt="$1" default="$2" reply
    if [[ -n "$default" ]]; then
        echo -en "  ${prompt} ${DIM}[${default}]${RESET}: " >&2
    else
        echo -en "  ${prompt}: " >&2
    fi
    read -rs reply
    echo "" >&2
    echo "${reply:-$default}"
}

# Yes/no prompt: confirm "Question" [y|n]
confirm() {
    local prompt="$1" default="${2:-n}" reply
    if [[ "$default" == "y" ]]; then
        echo -en "  ${prompt} ${DIM}[Y/n]${RESET}: " >&2
    else
        echo -en "  ${prompt} ${DIM}[y/N]${RESET}: " >&2
    fi
    read -r reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[yY] ]]
}

# ── Banner ────────────────────────────────────────────────────────────────────

clear
echo ""
echo -e "${BOLD}╔═══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   MacBook Pro A2141 — Ubuntu K8s ISO Builder (macOS)     ║${RESET}"
echo -e "${BOLD}╚═══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  This script will:"
echo -e "    1. Install required build tools via Homebrew"
echo -e "    2. Walk you through ISO configuration"
echo -e "    3. Build a custom Ubuntu Server 24.04 ISO with:"
echo -e "       • T2 Linux kernel + fan control"
echo -e "       • k3s Kubernetes single-node cluster"
echo -e "       • Fully automated (unattended) installation"
echo ""

if [[ ! -f "$BUILD_SCRIPT" ]]; then
    err "build-iso.sh not found at: ${BUILD_SCRIPT}"
    err "Run this script from the K8-SERVER directory."
    exit 1
fi

# ── Step 1: Install dependencies ─────────────────────────────────────────────

header "Step 1: Dependencies"

# Check for Homebrew
if ! command -v brew &>/dev/null; then
    warn "Homebrew is not installed."
    if confirm "Install Homebrew now?"; then
        info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # Add brew to PATH for Apple Silicon and Intel
        if [[ -f /opt/homebrew/bin/brew ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -f /usr/local/bin/brew ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        success "Homebrew installed."
    else
        err "Homebrew is required. Install it from https://brew.sh and re-run."
        exit 1
    fi
fi

TOOLS=("xorriso" "p7zip" "wget" "openssl")
CMDS=("xorriso" "7z" "wget" "openssl")
MISSING=()

for i in "${!CMDS[@]}"; do
    if command -v "${CMDS[$i]}" &>/dev/null; then
        success "${CMDS[$i]} found"
    else
        MISSING+=("${TOOLS[$i]}")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    info "Installing missing tools: ${MISSING[*]}"
    brew install "${MISSING[@]}"
    success "All tools installed."
else
    success "All dependencies already installed."
fi

# ── Step 2: Configuration ────────────────────────────────────────────────────

header "Step 2: System Identity"

TARGET_HOSTNAME=$(ask "Hostname" "k8s-macbook")
TARGET_USERNAME=$(ask "Username" "k8s")

echo ""
info "Set a password for the '${TARGET_USERNAME}' user."
info "This will be the login and sudo password on the target machine."
TARGET_PASSWORD=$(ask_password "Password" "changeme")
if [[ "$TARGET_PASSWORD" == "changeme" ]]; then
    warn "Using default password 'changeme' — change it after install!"
fi

# ── Locale & Timezone ────────────────────────────────────────────────────────

header "Step 3: Locale & Timezone"

# Try to detect macOS timezone
DETECTED_TZ=""
if command -v systemsetup &>/dev/null; then
    DETECTED_TZ=$(sudo systemsetup -gettimezone 2>/dev/null | sed 's/Time Zone: //' || true)
fi
if [[ -z "$DETECTED_TZ" && -f /etc/localtime ]]; then
    DETECTED_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)
fi
DETECTED_TZ="${DETECTED_TZ:-UTC}"

TARGET_TIMEZONE=$(ask "Timezone" "$DETECTED_TZ")
TARGET_LOCALE=$(ask "Locale" "en_US.UTF-8")
TARGET_KEYBOARD=$(ask "Keyboard layout" "us")

# ── SSH Keys ─────────────────────────────────────────────────────────────────

header "Step 4: SSH Keys"

SSH_KEYS=()
echo -e "  ${DIM}Adding SSH keys enables key-based auth and disables password login over SSH.${RESET}"
echo -e "  ${DIM}Without keys, password SSH login will be enabled.${RESET}"
echo ""

# Auto-detect keys
DETECTED_KEYS=()
for keyfile in ~/.ssh/id_*.pub; do
    [[ -f "$keyfile" ]] && DETECTED_KEYS+=("$keyfile")
done

if [[ ${#DETECTED_KEYS[@]} -gt 0 ]]; then
    info "Found SSH public keys on this machine:"
    for keyfile in "${DETECTED_KEYS[@]}"; do
        keyname=$(basename "$keyfile")
        keyfp=$(ssh-keygen -l -f "$keyfile" 2>/dev/null | awk '{print $2}') || keyfp="?"
        echo -e "    ${keyname}  ${DIM}(${keyfp})${RESET}"
    done
    echo ""
    if confirm "Add all detected keys?" "y"; then
        for keyfile in "${DETECTED_KEYS[@]}"; do
            SSH_KEYS+=("$(cat "$keyfile")")
        done
        success "Added ${#SSH_KEYS[@]} key(s)."
    fi
fi

if [[ ${#SSH_KEYS[@]} -eq 0 ]]; then
    if confirm "Paste an SSH public key manually?"; then
        while true; do
            echo -en "  SSH public key (or empty to finish): "
            read -r key
            [[ -z "$key" ]] && break
            if [[ "$key" =~ ^ssh- ]]; then
                SSH_KEYS+=("$key")
                success "Key added."
            else
                warn "Doesn't look like an SSH public key (should start with ssh-). Skipped."
            fi
        done
    fi
fi

if [[ ${#SSH_KEYS[@]} -eq 0 ]]; then
    warn "No SSH keys configured — password login over SSH will be enabled."
else
    success "${#SSH_KEYS[@]} SSH key(s) configured — password login over SSH will be disabled."
fi

# ── k3s Configuration ────────────────────────────────────────────────────────

header "Step 5: Kubernetes (k3s)"

echo -e "  ${DIM}k3s is a lightweight Kubernetes distribution. It will be installed${RESET}"
echo -e "  ${DIM}as a single-node cluster on first boot.${RESET}"
echo ""

K3S_DISABLE=$(ask "Components to disable (comma-separated)" "traefik")
K3S_TLS_SAN=$(ask "Extra TLS SANs for API server (comma-separated, or empty)" "")

# ── Ubuntu Version ────────────────────────────────────────────────────────────

header "Step 6: Ubuntu Version"

UBUNTU_VERSION=$(ask "Ubuntu Server version" "24.04.2")

# ── Output ────────────────────────────────────────────────────────────────────

OUTPUT_ISO="ubuntu-${UBUNTU_VERSION}-macbook-k8s.iso"
OUTPUT_ISO=$(ask "Output ISO filename" "$OUTPUT_ISO")

# ── Summary & Confirm ────────────────────────────────────────────────────────

header "Configuration Summary"

echo ""
echo -e "  ${BOLD}System${RESET}"
echo -e "    Hostname:       ${CYAN}${TARGET_HOSTNAME}${RESET}"
echo -e "    Username:       ${CYAN}${TARGET_USERNAME}${RESET}"
echo -e "    Password:       ${DIM}(set)${RESET}"
echo ""
echo -e "  ${BOLD}Locale${RESET}"
echo -e "    Timezone:       ${CYAN}${TARGET_TIMEZONE}${RESET}"
echo -e "    Locale:         ${CYAN}${TARGET_LOCALE}${RESET}"
echo -e "    Keyboard:       ${CYAN}${TARGET_KEYBOARD}${RESET}"
echo ""
echo -e "  ${BOLD}SSH${RESET}"
if [[ ${#SSH_KEYS[@]} -gt 0 ]]; then
    echo -e "    Keys:           ${CYAN}${#SSH_KEYS[@]} key(s) configured${RESET}"
    echo -e "    Password auth:  ${CYAN}disabled${RESET}"
else
    echo -e "    Keys:           ${YELLOW}none${RESET}"
    echo -e "    Password auth:  ${YELLOW}enabled${RESET}"
fi
echo ""
echo -e "  ${BOLD}Kubernetes${RESET}"
echo -e "    Disabled:       ${CYAN}${K3S_DISABLE:-none}${RESET}"
echo -e "    TLS SANs:       ${CYAN}${K3S_TLS_SAN:-none}${RESET}"
echo ""
echo -e "  ${BOLD}Build${RESET}"
echo -e "    Ubuntu:         ${CYAN}${UBUNTU_VERSION}${RESET}"
echo -e "    Output:         ${CYAN}${OUTPUT_ISO}${RESET}"
echo ""

if ! confirm "Proceed with build?" "y"; then
    echo ""
    warn "Aborted."
    exit 0
fi

# ── Build ─────────────────────────────────────────────────────────────────────

header "Building ISO"
echo ""

# Export configuration for build-iso.sh
export TARGET_HOSTNAME TARGET_USERNAME TARGET_PASSWORD
export TARGET_TIMEZONE TARGET_LOCALE TARGET_KEYBOARD
export K3S_DISABLE K3S_TLS_SAN
export UBUNTU_VERSION OUTPUT_ISO

# SSH_KEYS is an array — build-iso.sh reads it directly, so we source-export it
# by writing a temp env file that build-iso.sh will pick up
SSH_ENV=$(mktemp)
# shellcheck disable=SC2064
trap "rm -f '${SSH_ENV}'" EXIT

echo "SSH_KEYS=(" > "$SSH_ENV"
if [[ ${#SSH_KEYS[@]} -gt 0 ]]; then
    for key in "${SSH_KEYS[@]}"; do
        printf '  %q\n' "$key" >> "$SSH_ENV"
    done
fi
echo ")" >> "$SSH_ENV"

# Source the SSH keys into this shell so build-iso.sh inherits them
# shellcheck disable=SC1090
source "$SSH_ENV"

info "Running build-iso.sh..."
echo ""

bash "$BUILD_SCRIPT"
