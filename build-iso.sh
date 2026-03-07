#!/usr/bin/env bash
#
# build-iso.sh — Build custom Ubuntu Server 24.04 ISO for MacBook Pro A2141 (T2)
#
# Creates a fully automated (autoinstall) Ubuntu Server ISO with:
#   - T2 Linux kernel + fan control (t2fanrd)
#   - k3s Kubernetes single-node cluster
#   - Headless server config (no suspend, lid close ignored)
#   - SSH enabled
#
# Usage:
#   1. Edit the CONFIGURATION section below
#   2. Run: sudo bash build-iso.sh
#   3. Flash output ISO to USB: dd if=output.iso of=/dev/sdX bs=4M status=progress
#
# Prerequisites (build machine):
#   Linux: sudo apt install xorriso p7zip-full wget openssl
#   macOS: brew install xorriso p7zip wget openssl
#
# MacBook pre-install steps:
#   1. Boot macOS Recovery (Cmd+R)
#   2. Utilities → Startup Security Utility
#   3. Set Secure Boot → "No Security"
#   4. Set Allowed Boot Media → "Allow booting from external or removable media"
#   5. Plug in USB-to-Ethernet adapter
#   6. Boot holding Option (⌥), select USB drive
#
set -euo pipefail

# ===========================================================================
# CONFIGURATION — Edit these values
# ===========================================================================

# Ubuntu ISO
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04.2}"
UBUNTU_ISO_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}/ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"
UBUNTU_ISO_FILE="ubuntu-${UBUNTU_VERSION}-live-server-amd64.iso"

# Output
OUTPUT_ISO="${OUTPUT_ISO:-ubuntu-${UBUNTU_VERSION}-macbook-k8s.iso}"

# Target system identity
TARGET_HOSTNAME="${TARGET_HOSTNAME:-k8s-macbook}"
TARGET_USERNAME="${TARGET_USERNAME:-k8s}"
TARGET_PASSWORD="${TARGET_PASSWORD:-changeme}"   # plaintext or $6$ hash
TARGET_TIMEZONE="${TARGET_TIMEZONE:-UTC}"
TARGET_LOCALE="${TARGET_LOCALE:-en_US.UTF-8}"
TARGET_KEYBOARD="${TARGET_KEYBOARD:-us}"

# SSH — add your public keys (space-separated for multiple)
# Example: SSH_KEYS=("ssh-ed25519 AAAA... user@host")
SSH_KEYS=()

# k3s
K3S_DISABLE="${K3S_DISABLE:-traefik}"    # components to disable (comma-sep)
K3S_TLS_SAN="${K3S_TLS_SAN:-}"           # extra TLS SANs for API server

# Installer
REFRESH_INSTALLER="${REFRESH_INSTALLER:-false}"  # update installer over network before starting

# Tailscale
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"  # auth key for auto-join (optional)

# T2 Linux — check https://wiki.t2linux.org if these go stale
T2_REPO_URL="${T2_REPO_URL:-https://adityagarg8.github.io/t2-ubuntu-repo}"
T2_REPO_CODENAME="${T2_REPO_CODENAME:-noble}"

# ===========================================================================
# INTERNALS — no need to edit below unless debugging
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=""

red()    { echo -e "\033[0;31m$*\033[0m"; }
green()  { echo -e "\033[0;32m$*\033[0m"; }
yellow() { echo -e "\033[0;33m$*\033[0m"; }
info()   { echo -e "--- $*"; }
die()    { red "ERROR: $*" >&2; exit 1; }

# Portable sed in-place: macOS sed requires -i '', GNU sed requires -i
sedi() { sed -i'' -- "$@" 2>/dev/null || sed -i "$@"; }

cleanup() {
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]]; then
        info "Cleaning up ${WORK_DIR}"
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# ===========================================================================
# FUNCTIONS
# ===========================================================================

check_dependencies() {
    info "Checking dependencies..."
    local missing=()
    for cmd in xorriso 7z wget openssl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        red "Missing: ${missing[*]}"
        echo ""
        echo "Install on Ubuntu/Debian:"
        echo "  sudo apt install xorriso p7zip-full wget openssl"
        echo ""
        echo "Install on macOS:"
        echo "  brew install xorriso p7zip wget openssl"
        exit 1
    fi

    # Verify SHA-512 password hashing is available (macOS LibreSSL lacks -6)
    if [[ "$(uname)" == "Darwin" ]]; then
        local has_sha512=false
        for candidate in /opt/homebrew/opt/openssl/bin/openssl /usr/local/opt/openssl/bin/openssl; do
            if [[ -x "$candidate" ]] && "$candidate" passwd -6 "test" &>/dev/null; then
                has_sha512=true
                break
            fi
        done
        if ! $has_sha512; then
            red "macOS LibreSSL does not support SHA-512 password hashing."
            echo "  Install Homebrew OpenSSL: brew install openssl"
            exit 1
        fi
    fi

    green "All dependencies found."
}

download_iso() {
    if [[ -f "$UBUNTU_ISO_FILE" ]]; then
        info "ISO already exists: $UBUNTU_ISO_FILE"
        return
    fi
    info "Downloading Ubuntu Server ${UBUNTU_VERSION}..."
    wget -O "$UBUNTU_ISO_FILE" "$UBUNTU_ISO_URL"
    green "Download complete."
}

extract_iso() {
    info "Extracting ISO..."
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macbook-iso.XXXXXX")"
    local extract_dir="${WORK_DIR}/iso"

    7z x -y -o"${extract_dir}" "$UBUNTU_ISO_FILE" >/dev/null

    # 7z creates [BOOT] dir with El Torito boot images
    if [[ -f "${extract_dir}/[BOOT]/2-Boot-NoEmul.img" ]]; then
        cp "${extract_dir}/[BOOT]/2-Boot-NoEmul.img" "${WORK_DIR}/efi.img"
    else
        die "EFI boot image not found in ISO. Is this a valid Ubuntu Server ISO?"
    fi
    rm -rf "${extract_dir}/[BOOT]"

    # Extract MBR (first 432 bytes) for hybrid boot
    dd if="$UBUNTU_ISO_FILE" bs=1 count=432 of="${WORK_DIR}/mbr.img" 2>/dev/null

    chmod -R u+w "${extract_dir}"
    green "ISO extracted to ${extract_dir}"
}

generate_password_hash() {
    if [[ "$TARGET_PASSWORD" =~ ^\$6\$ ]]; then
        PASSWORD_HASH="$TARGET_PASSWORD"
        return
    fi

    # macOS LibreSSL doesn't support -6 (SHA-512), use Homebrew OpenSSL if available
    local openssl_bin="openssl"
    if [[ "$(uname)" == "Darwin" ]]; then
        for candidate in /opt/homebrew/opt/openssl/bin/openssl /usr/local/opt/openssl/bin/openssl; do
            if [[ -x "$candidate" ]]; then
                openssl_bin="$candidate"
                break
            fi
        done
    fi

    PASSWORD_HASH=$("$openssl_bin" passwd -6 "$TARGET_PASSWORD") \
        || die "Failed to generate password hash. On macOS, install OpenSSL: brew install openssl"
}

generate_user_data() {
    local outfile="${WORK_DIR}/iso/server/user-data"
    mkdir -p "$(dirname "$outfile")"
    touch "${WORK_DIR}/iso/server/meta-data"

    info "Generating autoinstall user-data..."

    # --- Header ---
    cat > "$outfile" << 'YAML'
#cloud-config
autoinstall:
  version: 1
YAML

    # Optional: update installer over network before starting
    if [[ "$REFRESH_INSTALLER" == "true" ]]; then
        cat >> "$outfile" << 'YAML'
  refresh-installer:
    update: true
YAML
    fi

    # --- Early commands (run before network probing) ---
    # shellcheck disable=SC2129
    cat >> "$outfile" << 'YAML'
  early-commands:
    - modprobe -r cdc_ether 2>/dev/null || true
    - modprobe r8152 2>/dev/null || true
    - modprobe ax88179_178a 2>/dev/null || true
    - sleep 3  # wait for USB ethernet device nodes to stabilize
YAML

    # --- Locale / Keyboard ---
    # shellcheck disable=SC2129
    cat >> "$outfile" << YAML
  locale: ${TARGET_LOCALE}
  keyboard:
    layout: ${TARGET_KEYBOARD}
YAML

    # --- Identity ---
    {
        echo "  identity:"
        echo "    hostname: ${TARGET_HOSTNAME}"
        echo "    username: ${TARGET_USERNAME}"
        printf '    password: "%s"\n' "$PASSWORD_HASH"
    } >> "$outfile"

    # --- SSH ---
    {
        echo "  ssh:"
        echo "    install-server: true"
        if [[ ${#SSH_KEYS[@]} -gt 0 ]]; then
            echo "    allow-pw: false"
            echo "    authorized-keys:"
            for key in "${SSH_KEYS[@]}"; do
                echo "      - \"${key}\""
            done
        else
            echo "    allow-pw: true"
        fi
    } >> "$outfile"

    # --- Network / Storage / Packages ---
    cat >> "$outfile" << 'YAML'
  network:
    version: 2
    ethernets:
      all-en:
        match:
          name: "en*"
        dhcp4: true
      all-eth:
        match:
          name: "eth*"
        dhcp4: true
  storage:
    layout:
      name: lvm
      sizing-policy: all
  apt:
    disable_components: []
    preserve_sources_list: false
    primary:
      - arches: [amd64]
        uri: "http://archive.ubuntu.com/ubuntu"
    geoip: false
  packages:
    - wget
  package_update: false
  package_upgrade: false
YAML

    # --- Late-commands (during install, target at /target) ---
    cat >> "$outfile" << 'YAML'
  late-commands:
    # Kernel modules for Kubernetes
    - |
      cat > /target/etc/modules-load.d/k8s.conf << 'EOF'
      br_netfilter
      overlay
      EOF
    # Sysctl for Kubernetes networking
    - |
      cat > /target/etc/sysctl.d/99-kubernetes.conf << 'EOF'
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward = 1
      EOF
    # Disable suspend on lid close
    - mkdir -p /target/etc/systemd/logind.conf.d
    - |
      cat > /target/etc/systemd/logind.conf.d/lid.conf << 'EOF'
      [Login]
      HandleLidSwitch=ignore
      HandleLidSwitchExternalPower=ignore
      HandleLidSwitchDocked=ignore
      EOF
    # Disable all sleep/hibernate
    - mkdir -p /target/etc/systemd/sleep.conf.d
    - |
      cat > /target/etc/systemd/sleep.conf.d/nosleep.conf << 'EOF'
      [Sleep]
      AllowSuspend=no
      AllowHibernation=no
      AllowHybridSleep=no
      AllowSuspendThenHibernate=no
      EOF
    # Disable swap
    - sed -i '/\sswap\s/s/^/#/' /target/etc/fstab
    # Console blanking for headless (blank after 30s)
    - sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="consoleblank=30"/' /target/etc/default/grub
    - curtin in-target --target=/target -- update-grub
YAML

    # k3s config pre-creation (needs variable injection)
    {
        echo "    # Pre-create k3s config"
        echo "    - curtin in-target --target=/target -- mkdir -p /etc/rancher/k3s"
        echo "    - |"
        echo "      cat > /target/etc/rancher/k3s/config.yaml << 'EOF'"
        echo "      write-kubeconfig-mode: \"0644\""
        if [[ -n "$K3S_TLS_SAN" ]]; then
            echo "      tls-san:"
            IFS=',' read -ra SANS <<< "$K3S_TLS_SAN"
            for san in "${SANS[@]}"; do
                echo "        - \"$(echo "$san" | xargs)\""
            done
        fi
        if [[ -n "$K3S_DISABLE" ]]; then
            echo "      disable:"
            IFS=',' read -ra COMPONENTS <<< "$K3S_DISABLE"
            for comp in "${COMPONENTS[@]}"; do
                echo "        - $(echo "$comp" | xargs)"
            done
        fi
        echo "      EOF"
    } >> "$outfile"

    # Copy setup script from ISO to target
    {
        echo "    # Copy first-boot setup script"
        echo "    - cp /cdrom/extras/macbook-setup.sh /target/opt/macbook-setup.sh"
        echo "    - chmod +x /target/opt/macbook-setup.sh"
    } >> "$outfile"

    # --- Error commands (dump diagnostics to boot media for debugging) ---
    cat >> "$outfile" << 'YAML'
  error-commands:
    # NOTE: remount,rw only works on FAT32 boot media (flash-efi.sh); silently fails on ISO9660
    - mount -o remount,rw /cdrom 2>/dev/null || true
    - mkdir -p /cdrom/debug
    - ip a > /cdrom/debug/network.log 2>&1 || true
    - lsusb > /cdrom/debug/usb-devices.log 2>&1 || true
    - dmesg | grep -iE 'r8152|cdc|ax88|eth|usb|net' > /cdrom/debug/dmesg-net.log 2>&1 || true
    - cat /var/log/installer/curtin-install.log > /cdrom/debug/curtin-install.log 2>&1 || true
    - ls -la /cdrom/ > /cdrom/debug/cdrom-permissions.log 2>&1 || true
    - ls -laR /cdrom/dists/ >> /cdrom/debug/cdrom-permissions.log 2>&1 || true
YAML

    # Inject timezone (top-level autoinstall key)
    cat >> "$outfile" << YAML
  timezone: ${TARGET_TIMEZONE}
YAML

    # --- First-boot runcmd ---
    cat >> "$outfile" << 'YAML'
  user-data:
    runcmd:
      - /opt/macbook-setup.sh
YAML

    green "user-data generated."
}

generate_setup_script() {
    local outfile="${WORK_DIR}/iso/extras/macbook-setup.sh"
    mkdir -p "$(dirname "$outfile")"

    info "Generating first-boot setup script..."

    cat > "$outfile" << SETUP_HEADER
#!/usr/bin/env bash
#
# macbook-setup.sh — First-boot setup for MacBook Pro A2141
# Installs system packages, T2 Linux kernel, fan control, k3s, and Tailscale
# Log: /var/log/macbook-setup.log
#
set -euo pipefail

MARKER="/opt/.macbook-setup-complete"
LOG="/var/log/macbook-setup.log"
USERNAME="${TARGET_USERNAME}"
T2_REPO_URL="${T2_REPO_URL}"
T2_REPO_CODENAME="${T2_REPO_CODENAME}"

if [[ -f "\$MARKER" ]]; then
    echo "Setup already completed. Remove \$MARKER to re-run."
    exit 0
fi

exec > >(tee -a "\$LOG") 2>&1
echo "========================================="
echo "MacBook K8s Setup — \$(date)"
echo "========================================="

SETUP_HEADER

    cat >> "$outfile" << 'SETUP_BODY'

# -----------------------------------------------
# 1. System packages (moved from autoinstall for offline-safe ISO)
# -----------------------------------------------
echo ""
echo "[1/6] Installing system packages..."

apt-get update || {
    echo "WARNING: apt-get update failed, retrying in 10s..."
    sleep 10
    apt-get update
}
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl vim htop tmux net-tools lm-sensors \
    open-iscsi nfs-common ca-certificates gnupg apt-transport-https

# -----------------------------------------------
# 2. T2 Linux repository + kernel
# -----------------------------------------------
echo ""
echo "[2/6] Adding T2 Linux repository..."

if curl -sfL "${T2_REPO_URL}/KEY.gpg" -o /tmp/t2-key.gpg 2>/dev/null; then
    gpg --dearmor -o /etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg < /tmp/t2-key.gpg
    echo "deb [signed-by=/etc/apt/trusted.gpg.d/t2-ubuntu-repo.gpg] ${T2_REPO_URL} ${T2_REPO_CODENAME} main" \
        > /etc/apt/sources.list.d/t2-linux.list
    apt-get update -qq

    echo "Installing T2 Linux kernel..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y linux-t2 2>/dev/null || {
        echo "WARNING: linux-t2 meta-package not found."
        echo "Trying individual kernel package..."
        # Fallback: find the latest t2 kernel in the repo
        T2_KERNEL=$(apt-cache search 'linux-image.*t2' | head -1 | awk '{print $1}')
        if [[ -n "$T2_KERNEL" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$T2_KERNEL"
        else
            echo "WARNING: No T2 kernel found. Check https://wiki.t2linux.org"
            echo "Fan control and WiFi will not work until T2 kernel is installed."
        fi
    }
else
    echo "WARNING: Cannot reach T2 Linux repo at ${T2_REPO_URL}"
    echo "Skipping T2 kernel install. You can re-run /opt/macbook-setup.sh later."
fi

# System upgrade (after T2 kernel so upgrades apply on the correct kernel base)
echo "Running system upgrade..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || echo "WARNING: System upgrade failed, continuing..."

# -----------------------------------------------
# 3. Fan control (t2fanrd)
# -----------------------------------------------
echo ""
echo "[3/6] Setting up fan control..."

if apt-cache show t2fanrd &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y t2fanrd
    systemctl enable t2fanrd 2>/dev/null || true
    echo "t2fanrd installed and enabled."
else
    echo "WARNING: t2fanrd not in repo. Trying manual install..."
    # Fallback: try the t2linux wiki recommended approach
    if apt-cache show t2fand &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y t2fand
        systemctl enable t2fand 2>/dev/null || true
        echo "t2fand installed and enabled."
    else
        echo "WARNING: No T2 fan daemon found."
        echo "CRITICAL: Without fan control the MacBook may overheat!"
        echo "Check https://wiki.t2linux.org for manual installation."
    fi
fi

# -----------------------------------------------
# 4. Install k3s
# -----------------------------------------------
echo ""
echo "[4/6] Installing k3s..."

export INSTALL_K3S_SKIP_START=false
curl -sfL https://get.k3s.io | sh -s -

echo "Waiting for k3s to be ready..."
TRIES=0
until /usr/local/bin/kubectl get nodes 2>/dev/null; do
    TRIES=$((TRIES + 1))
    if [[ $TRIES -gt 60 ]]; then
        echo "WARNING: k3s did not become ready in 3 minutes."
        echo "Check: systemctl status k3s"
        break
    fi
    sleep 3
done

echo "k3s node status:"
/usr/local/bin/kubectl get nodes 2>/dev/null || true

SETUP_BODY

    # Tailscale section — needs variable injection for auth key
    cat >> "$outfile" << SETUP_TAILSCALE

# -----------------------------------------------
# 5. Install Tailscale
# -----------------------------------------------
echo ""
echo "[5/6] Installing Tailscale..."

if curl -fsSL https://tailscale.com/install.sh -o /tmp/tailscale-install.sh 2>/dev/null; then
    sh /tmp/tailscale-install.sh
    systemctl enable tailscaled
    systemctl start tailscaled
    echo "Tailscale installed and enabled."
SETUP_TAILSCALE

    if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        cat >> "$outfile" << SETUP_TS_AUTH
    tailscale up --authkey=${TAILSCALE_AUTH_KEY} --advertise-routes=10.42.0.0/16,10.43.0.0/16
    echo "Tailscale joined with auth key. Advertising k3s pod/service CIDRs."
    echo "NOTE: Approve subnet routes in the Tailscale admin console."
SETUP_TS_AUTH
    else
        cat >> "$outfile" << 'SETUP_TS_MANUAL'
    echo "Tailscale installed but no auth key provided."
    echo "To join your tailnet, run:"
    echo "  sudo tailscale up --advertise-routes=10.42.0.0/16,10.43.0.0/16"
    echo "Then approve the device and subnet routes in the Tailscale admin console."
SETUP_TS_MANUAL
    fi

    cat >> "$outfile" << 'SETUP_TS_ELSE'
else
    echo "WARNING: Could not download Tailscale installer."
    echo "Install manually later: https://tailscale.com/download/linux"
fi
SETUP_TS_ELSE

    cat >> "$outfile" << 'SETUP_BODY'

# -----------------------------------------------
# 6. Configure user environment
# -----------------------------------------------
echo ""
echo "[6/6] Configuring user environment..."

# kubectl access
if ! grep -q 'KUBECONFIG' "/home/${USERNAME}/.bashrc" 2>/dev/null; then
    echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> "/home/${USERNAME}/.bashrc"
fi

# kubectl completion
/usr/local/bin/kubectl completion bash > /etc/bash_completion.d/kubectl 2>/dev/null || true

# Alias for convenience
if ! grep -q 'alias k=' "/home/${USERNAME}/.bashrc" 2>/dev/null; then
    echo "alias k='kubectl'" >> "/home/${USERNAME}/.bashrc"
    echo "complete -o default -F __start_kubectl k" >> "/home/${USERNAME}/.bashrc"
fi

# -----------------------------------------------
# Done
# -----------------------------------------------
echo ""
echo "========================================="
echo "Setup complete!"
echo ""
echo "  Hostname:  $(hostname)"
echo "  User:      ${USERNAME}"
echo "  k3s:       $(k3s --version 2>/dev/null || echo 'check manually')"
echo "  Tailscale: $(tailscale version 2>/dev/null | head -1 || echo 'check manually')"
echo "  Kernel:    $(uname -r)"
echo ""
echo "A reboot is needed to activate the T2 kernel."
echo "Rebooting in 60 seconds... (cancel: shutdown -c)"
echo "========================================="

touch "$MARKER"
shutdown -r +1 "Rebooting to activate T2 Linux kernel"
SETUP_BODY

    chmod +x "$outfile"
    green "Setup script generated."
}

modify_grub() {
    local extract_dir="${WORK_DIR}/iso"
    local grub_cfg="${extract_dir}/boot/grub/grub.cfg"

    info "Modifying GRUB configuration..."

    if [[ ! -f "$grub_cfg" ]]; then
        die "GRUB config not found at ${grub_cfg}"
    fi

    # Add autoinstall + nocloud datasource + T2/USB compatibility params to all boot entries
    # - modprobe.blacklist=cdc_ether: prevent generic driver from stealing USB ethernet (RTL8153)
    # - usbcore.autosuspend=-1: prevent USB hubs from power-saving disconnects
    # - pcie_ports=compat: improve Thunderbolt/PCIe stability on T2 Macs
    # Use flexible whitespace matching — Ubuntu grub.cfg may use tabs or multiple spaces
    local kernel_params="autoinstall ds=nocloud\\\\;s=/cdrom/server/ modprobe.blacklist=cdc_ether usbcore.autosuspend=-1 pcie_ports=compat console=ttyS0,115200n8"
    sedi "s|/casper/vmlinuz\(.*\)---|/casper/vmlinuz ${kernel_params} \1---|g" "$grub_cfg"

    # Also handle HWE kernel entries if present
    sedi "s|/casper/hwe-vmlinuz\(.*\)---|/casper/hwe-vmlinuz ${kernel_params} \1---|g" "$grub_cfg"

    # Set timeout so it auto-boots (default entry)
    sedi 's/^set timeout=.*/set timeout=5/' "$grub_cfg"

    # Verify autoinstall was actually injected
    if ! grep -q 'autoinstall' "$grub_cfg"; then
        red "GRUB injection FAILED — 'autoinstall' not found in grub.cfg"
        red "--- grub.cfg contents (first 50 lines) ---"
        head -50 "$grub_cfg" >&2
        die "sed pattern did not match any kernel boot lines. Check grub.cfg format."
    fi

    # Also modify loopback.cfg if present
    local loopback="${extract_dir}/boot/grub/loopback.cfg"
    if [[ -f "$loopback" ]]; then
        sedi "s|/casper/vmlinuz\(.*\)---|/casper/vmlinuz ${kernel_params} \1---|g" "$loopback"
        sedi "s|/casper/hwe-vmlinuz\(.*\)---|/casper/hwe-vmlinuz ${kernel_params} \1---|g" "$loopback"
    fi

    # Create standalone EFI/BOOT/grub.cfg fallback
    # This is self-contained — doesn't depend on GRUB's embedded prefix resolving correctly.
    # On T2 Macs with SD cards or FAT32 USB, the GRUB binary inside efi.img may fail to
    # chain-load boot/grub/grub.cfg. This fallback sits next to BOOTX64.EFI where GRUB
    # always looks as a last resort.
    local efi_boot_dir="${extract_dir}/EFI/BOOT"
    mkdir -p "$efi_boot_dir"
    cat > "${efi_boot_dir}/grub.cfg" << 'GRUB_FALLBACK'
search --set=root --file /casper/vmlinuz
set default=0
set timeout=5

menuentry "Install Ubuntu Server (autoinstall)" {
    linux ($root)/casper/vmlinuz autoinstall ds=nocloud\;s=/cdrom/server/ modprobe.blacklist=cdc_ether usbcore.autosuspend=-1 pcie_ports=compat console=ttyS0,115200n8 quiet ---
    initrd ($root)/casper/initrd
}
menuentry "Install Ubuntu Server - HWE kernel (autoinstall)" {
    linux ($root)/casper/hwe-vmlinuz autoinstall ds=nocloud\;s=/cdrom/server/ modprobe.blacklist=cdc_ether usbcore.autosuspend=-1 pcie_ports=compat console=ttyS0,115200n8 quiet ---
    initrd ($root)/casper/hwe-initrd
}
GRUB_FALLBACK
    info "Created EFI/BOOT/grub.cfg fallback."

    green "GRUB modified for autoinstall."
}

repack_iso() {
    local extract_dir="${WORK_DIR}/iso"

    info "Repacking ISO..."

    # Regenerate md5sum (optional but nice)
    if cd "$extract_dir"; then
        find . -type f -not -name 'md5sum.txt' -print0 | xargs -0 md5sum > md5sum.txt 2>/dev/null || true
        cd - >/dev/null
    fi

    # -dir-mode/-file-mode: ensure _apt user can read /cdrom during install (LP#1963725)
    xorriso -as mkisofs -r \
        -V "Ubuntu K8s MacBook" \
        -dir-mode 0755 \
        -file-mode 0644 \
        -o "${SCRIPT_DIR}/${OUTPUT_ISO}" \
        --grub2-mbr "${WORK_DIR}/mbr.img" \
        -partition_offset 16 \
        --mbr-force-bootable \
        -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "${WORK_DIR}/efi.img" \
        -appended_part_as_gpt \
        -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
        -c '/boot.catalog' \
        -b '/boot/grub/i386-pc/eltorito.img' \
            -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
        -eltorito-alt-boot \
        -e '--interval:appended_partition_2:::' \
        -no-emul-boot \
        "$extract_dir"

    green "ISO created: ${SCRIPT_DIR}/${OUTPUT_ISO}"
}

print_instructions() {
    local iso_path="${SCRIPT_DIR}/${OUTPUT_ISO}"
    local iso_size
    iso_size=$(du -h "$iso_path" | cut -f1)

    echo ""
    echo "==========================================="
    green " BUILD COMPLETE"
    echo "==========================================="
    echo ""
    echo "  ISO:  ${iso_path}"
    echo "  Size: ${iso_size}"
    echo ""
    echo "--- Flash to USB ---"
    echo ""
    echo "  Linux:"
    echo "    sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "  macOS:"
    echo "    sudo dd if=${OUTPUT_ISO} of=/dev/rdiskN bs=4m"
    echo "    (find disk with: diskutil list)"
    echo ""
    echo "--- MacBook A2141 Boot Steps ---"
    echo ""
    echo "  1. Ensure Secure Boot is OFF (macOS Recovery → Startup Security Utility)"
    echo "  2. Plug in USB-to-Ethernet adapter"
    echo "  3. Insert USB drive"
    echo "  4. Power on holding Option (⌥) key"
    echo "  5. Select 'EFI Boot' (the USB drive)"
    echo "  6. GRUB will auto-boot the installer in 5 seconds"
    echo "  7. Installation is fully automatic (~10-15 min)"
    echo "  8. System reboots, first-boot setup runs (~5 min)"
    echo "  9. System reboots again (T2 kernel activation)"
    echo " 10. SSH in: ssh ${TARGET_USERNAME}@<ip-address>"
    echo ""
    echo "--- Post-Install ---"
    echo ""
    echo "  Check setup log:  cat /var/log/macbook-setup.log"
    echo "  Re-run setup:     rm /opt/.macbook-setup-complete && sudo /opt/macbook-setup.sh"
    echo "  Check k3s:        kubectl get nodes"
    echo "  Check fans:       systemctl status t2fanrd"
    echo "  Check temps:      sensors"
    echo ""
    echo "--- WiFi (optional, needs macOS firmware) ---"
    echo ""
    echo "  The BCM4364 WiFi chip requires firmware extracted from macOS."
    echo "  See: https://wiki.t2linux.org/guides/wifi/"
    echo ""
    echo "==========================================="
}

# ===========================================================================
# MAIN
# ===========================================================================

main() {
    echo ""
    echo "==========================================="
    echo " MacBook Pro A2141 — Ubuntu K8s ISO Builder"
    echo "==========================================="
    echo ""
    echo "  Target:   ${TARGET_HOSTNAME} (${TARGET_USERNAME})"
    echo "  Ubuntu:   ${UBUNTU_VERSION}"
    echo "  Output:   ${OUTPUT_ISO}"
    echo ""

    # Check if output already exists
    if [[ -f "${SCRIPT_DIR}/${OUTPUT_ISO}" ]]; then
        yellow "Output ISO already exists: ${OUTPUT_ISO}"
        if [[ -t 0 ]]; then
            read -rp "Overwrite? [y/N] " confirm
            if [[ "$confirm" != [yY] ]]; then
                echo "Aborted."
                exit 0
            fi
        else
            info "Non-interactive mode — overwriting."
        fi
        rm -f "${SCRIPT_DIR}/${OUTPUT_ISO}"
    fi

    check_dependencies
    download_iso
    extract_iso
    generate_password_hash
    generate_user_data
    generate_setup_script
    modify_grub
    repack_iso
    print_instructions
}

main "$@"
