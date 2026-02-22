#!/usr/bin/env bash
#
# flash-efi.sh — Flash ISO to SD card / USB as EFI-bootable volume
#
# On T2 Macs, `dd`-ing a hybrid ISO to an SD card often doesn't produce
# bootable media — the Option boot menu ignores it. This script creates a
# clean GPT + FAT32 partition with a proper EFI/BOOT/BOOTX64.EFI structure
# and copies the full ISO contents onto it.
#
# Usage:
#   sudo bash flash-efi.sh /dev/disk4
#
# Environment variable overrides:
#   ISO_FILE — path to built ISO (auto-detected in repo dir)
#
set -euo pipefail

# ===========================================================================
# CONFIGURATION
# ===========================================================================

ISO_FILE="${ISO_FILE:-}"

# ===========================================================================
# INTERNALS
# ===========================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=""

red()    { echo -e "\033[0;31m$*\033[0m"; }
green()  { echo -e "\033[0;32m$*\033[0m"; }
yellow() { echo -e "\033[0;33m$*\033[0m"; }
info()   { echo -e "--- $*"; }
die()    { red "ERROR: $*" >&2; exit 1; }

cleanup() {
    # Unmount if we mounted on Linux
    if [[ "$(uname)" != "Darwin" && -d "${WORK_DIR:-}/mount" ]]; then
        umount "${WORK_DIR}/mount" 2>/dev/null || true
    fi
    if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]]; then
        info "Cleaning up ${WORK_DIR}"
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT INT TERM

# ===========================================================================
# FUNCTIONS
# ===========================================================================

check_dependencies() {
    info "Checking dependencies..."
    local missing=()
    if ! command -v 7z &>/dev/null; then
        missing+=("7z")
    fi
    if [[ "$(uname)" == "Darwin" ]]; then
        if ! command -v diskutil &>/dev/null; then
            missing+=("diskutil")
        fi
    else
        for cmd in parted mkfs.fat; do
            if ! command -v "$cmd" &>/dev/null; then
                missing+=("$cmd")
            fi
        done
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        red "Missing: ${missing[*]}"
        echo ""
        echo "Install on Ubuntu/Debian:"
        echo "  sudo apt install p7zip-full parted dosfstools"
        echo ""
        echo "Install on macOS:"
        echo "  brew install p7zip"
        exit 1
    fi
    green "All dependencies found."
}

find_iso() {
    if [[ -n "$ISO_FILE" ]]; then
        [[ -f "$ISO_FILE" ]] || die "ISO not found: ${ISO_FILE}"
        return
    fi
    # Auto-detect in repo directory
    local candidates
    candidates=("${SCRIPT_DIR}"/ubuntu-*-macbook-k8s.iso)
    if [[ -f "${candidates[0]:-}" ]]; then
        ISO_FILE="${candidates[0]}"
        info "Found ISO: ${ISO_FILE}"
    else
        die "No ISO found. Run build-iso.sh first, or set ISO_FILE=/path/to/iso"
    fi
}

extract_iso() {
    info "Extracting ISO contents..."
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/flash-efi.XXXXXX")"
    local extract_dir="${WORK_DIR}/iso"

    7z x -y -o"${extract_dir}" "$ISO_FILE" >/dev/null

    # 7z creates [BOOT] dir with El Torito images — we need the EFI binary from it
    if [[ -f "${extract_dir}/[BOOT]/2-Boot-NoEmul.img" ]]; then
        local efi_img="${extract_dir}/[BOOT]/2-Boot-NoEmul.img"
        local efi_tmp="${WORK_DIR}/efi_tmp"
        mkdir -p "$efi_tmp"

        # Extract GRUB EFI binary from the EFI boot image
        7z x -y -o"${efi_tmp}" "$efi_img" >/dev/null 2>&1 || true

        local efi_binary
        efi_binary=$(find "$efi_tmp" -iname "BOOTX64.EFI" -print -quit 2>/dev/null) || true
        if [[ -n "$efi_binary" ]]; then
            mkdir -p "${extract_dir}/EFI/BOOT"
            cp "$efi_binary" "${extract_dir}/EFI/BOOT/BOOTX64.EFI"
        fi
        rm -rf "${efi_tmp}"
    fi
    rm -rf "${extract_dir}/[BOOT]"

    # Verify we have what we need
    local efi_path
    efi_path=$(find "${extract_dir}" -ipath "*/EFI/BOOT/BOOTX64.EFI" -print -quit 2>/dev/null) || true
    [[ -n "$efi_path" ]] || die "BOOTX64.EFI not found in ISO. Is this a valid Ubuntu Server ISO?"
    [[ -f "${extract_dir}/casper/vmlinuz" ]] || die "vmlinuz not found in ISO"
    [[ -f "${extract_dir}/casper/initrd" ]] || die "initrd not found in ISO"

    local extract_size
    extract_size=$(du -sh "${extract_dir}" 2>/dev/null | cut -f1)
    green "ISO extracted (${extract_size})."
}

format_device() {
    local device="$1"

    if [[ ! -e "$device" ]]; then
        die "Device not found: ${device}"
    fi

    echo ""
    yellow "WARNING: This will ERASE ALL DATA on ${device}!"
    echo ""

    if [[ "$(uname)" == "Darwin" ]]; then
        diskutil info "$device" 2>/dev/null | grep -E '(Device Node|Media Name|Disk Size|Volume Name)' || true
    else
        lsblk "$device" 2>/dev/null || true
    fi

    echo ""
    read -rp "Type YES to proceed: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Aborted."
        exit 0
    fi

    info "Formatting ${device} as GPT + FAT32..."
    if [[ "$(uname)" == "Darwin" ]]; then
        diskutil eraseDisk FAT32 EFIBOOT GPT "$device"
        VOLUME_PATH="/Volumes/EFIBOOT"
        if [[ ! -d "$VOLUME_PATH" ]]; then
            die "Volume EFIBOOT not mounted after format. Check diskutil output."
        fi
    else
        # Unmount any existing partitions
        umount "${device}"* 2>/dev/null || true

        parted -s "$device" mklabel gpt
        parted -s "$device" mkpart primary fat32 1MiB 100%
        parted -s "$device" set 1 esp on

        # Determine partition device name
        local part_device="${device}1"
        if [[ "$device" =~ [0-9]$ ]]; then
            part_device="${device}p1"
        fi

        mkfs.fat -F32 -n EFIBOOT "$part_device"

        VOLUME_PATH="${WORK_DIR}/mount"
        mkdir -p "$VOLUME_PATH"
        mount "$part_device" "$VOLUME_PATH"
    fi

    green "Formatted."
}

copy_files() {
    local extract_dir="${WORK_DIR}/iso"

    info "Copying ISO contents to ${VOLUME_PATH}..."

    # Copy everything from the extracted ISO
    # Use cp -a to preserve structure; exclude [BOOT] which we already cleaned up
    cp -a "${extract_dir}/." "${VOLUME_PATH}/"

    # Ensure the EFI binary is at the canonical path
    if [[ ! -f "${VOLUME_PATH}/EFI/BOOT/BOOTX64.EFI" ]]; then
        # Check case-insensitive
        local existing
        existing=$(find "${VOLUME_PATH}" -ipath "*/EFI/BOOT/BOOTX64.EFI" -print -quit 2>/dev/null) || true
        if [[ -n "$existing" ]]; then
            mkdir -p "${VOLUME_PATH}/EFI/BOOT"
            cp "$existing" "${VOLUME_PATH}/EFI/BOOT/BOOTX64.EFI"
        else
            die "BOOTX64.EFI missing after copy — this should not happen"
        fi
    fi

    local total_size
    total_size=$(du -sh "$VOLUME_PATH" 2>/dev/null | cut -f1)
    green "Copied (${total_size} total)."
}

eject_device() {
    local device="$1"

    if [[ "$(uname)" != "Darwin" && -d "${WORK_DIR}/mount" ]]; then
        info "Unmounting..."
        sync
        umount "${WORK_DIR}/mount"
    fi

    if [[ "$(uname)" == "Darwin" ]]; then
        info "Ejecting..."
        sync
        diskutil eject "$device" 2>/dev/null || true
    fi

    green "Device ready to remove."
}

print_instructions() {
    echo ""
    echo "==========================================="
    green " FLASH COMPLETE"
    echo "==========================================="
    echo ""
    echo "--- MacBook A2141 Boot Steps ---"
    echo ""
    echo "  1. Ensure Secure Boot is OFF (macOS Recovery → Startup Security Utility)"
    echo "  2. Plug in USB-to-Ethernet adapter"
    echo "  3. Insert the SD card / USB into the target MacBook"
    echo "  4. Power on holding Option (⌥) key"
    echo "  5. Select 'EFI Boot' or 'EFIBOOT'"
    echo "  6. GRUB will auto-boot the installer in 5 seconds"
    echo "  7. Installation runs fully unattended (~10-15 min)"
    echo "  8. System reboots, first-boot setup runs (~5 min)"
    echo "  9. System reboots again (T2 kernel activation)"
    echo " 10. SSH in: ssh <username>@<ip-address>"
    echo ""
    echo "--- Troubleshooting ---"
    echo ""
    echo "  • No 'EFI Boot' in Option menu: ensure Secure Boot is disabled"
    echo "  • Stuck at GRUB: check that the SD card has EFI/BOOT/BOOTX64.EFI"
    echo "  • Falls back to dd: sudo dd if=<iso> of=/dev/rdiskN bs=4m"
    echo ""
    echo "==========================================="
}

# ===========================================================================
# MAIN
# ===========================================================================

main() {
    local device=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                echo "Usage: flash-efi.sh [OPTIONS] DEVICE"
                echo ""
                echo "Flash the built ISO to an SD card or USB as an EFI-bootable FAT32 volume."
                echo ""
                echo "On T2 Macs, dd-ing a hybrid ISO to an SD card often doesn't produce"
                echo "bootable media. This script creates a clean GPT + FAT32 partition with"
                echo "a proper EFI structure that the T2 firmware recognizes."
                echo ""
                echo "Arguments:"
                echo "  DEVICE            Block device (e.g., /dev/disk4 on macOS, /dev/sdb on Linux)"
                echo ""
                echo "Options:"
                echo "  -h, --help        Show this help"
                echo ""
                echo "Environment variables:"
                echo "  ISO_FILE          Path to built ISO (auto-detected)"
                exit 0
                ;;
            -*)
                die "Unknown option: $1 (use --help for usage)"
                ;;
            *)
                device="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$device" ]]; then
        die "No device specified. Usage: sudo bash flash-efi.sh /dev/diskN"
    fi

    echo ""
    echo "==========================================="
    echo " MacBook Pro A2141 — EFI Flash Tool"
    echo "==========================================="
    echo ""

    check_dependencies
    find_iso
    extract_iso
    format_device "$device"
    copy_files
    eject_device "$device"
    print_instructions
}

main "$@"
