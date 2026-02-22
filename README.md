# mac-server

Custom Ubuntu Server 24.04 ISO builder for running a single-node Kubernetes cluster on a MacBook Pro A2141 (16" 2019, T2 chip).

One script turns the stock Ubuntu Server ISO into a fully automated installer that configures everything for headless server use.

## What you get

| Component | Detail |
|---|---|
| OS | Ubuntu Server 24.04 LTS (headless, no GUI) |
| Kubernetes | k3s single-node cluster |
| Fan control | t2fanrd (T2-aware, server-tuned) |
| Lid close | Ignored — no suspend |
| Sleep/hibernate | Fully disabled |
| SSH | Enabled at install time |
| T2 kernel | Installed on first boot for hardware support |

## Prerequisites

### Build machine

```bash
# Ubuntu/Debian
sudo apt install xorriso p7zip-full wget openssl

# macOS
brew install xorriso p7zip wget openssl
```

### MacBook prep (one-time)

1. Boot into macOS Recovery (`Cmd + R`)
2. Go to **Utilities > Startup Security Utility**
3. Set Secure Boot to **No Security**
4. Set Allowed Boot Media to **Allow booting from external or removable media**

### Hardware

- USB-to-Ethernet adapter (for network during install)
- USB flash drive (4GB+)

## Configure

Edit the configuration section at the top of `build-iso.sh`:

```bash
TARGET_HOSTNAME="k8s-macbook"
TARGET_USERNAME="k8s"
TARGET_PASSWORD="changeme"       # change this
SSH_KEYS=("ssh-ed25519 AAAA...") # your public key
K3S_TLS_SAN="192.168.1.100"     # your server IP
```

All settings can also be passed as environment variables:

```bash
TARGET_PASSWORD="hunter2" K3S_TLS_SAN="k8s.local" bash build-iso.sh
```

## Build

```bash
bash build-iso.sh
```

This downloads the Ubuntu Server ISO (~2.5 GB, cached), injects the autoinstall config, and produces `ubuntu-24.04.2-macbook-k8s.iso`.

## Flash

```bash
# Linux
sudo dd if=ubuntu-24.04.2-macbook-k8s.iso of=/dev/sdX bs=4M status=progress

# macOS (find disk with: diskutil list)
sudo dd if=ubuntu-24.04.2-macbook-k8s.iso of=/dev/rdiskN bs=4m
```

## Install

1. Plug in USB-to-Ethernet adapter and USB drive
2. Power on the MacBook holding **Option (&#8997;)**
3. Select **EFI Boot** (the USB drive)
4. GRUB auto-boots the installer in 5 seconds
5. Installation runs fully unattended (~10-15 min)
6. System reboots, first-boot setup installs T2 kernel + k3s (~5 min)
7. System reboots once more to activate the T2 kernel
8. SSH in: `ssh <username>@<ip-address>`

## Post-install

```bash
# Check setup log
cat /var/log/macbook-setup.log

# Verify k3s
kubectl get nodes

# Check fan control
systemctl status t2fanrd

# Check temperatures
sensors

# Re-run setup if needed
sudo rm /opt/.macbook-setup-complete && sudo /opt/macbook-setup.sh
```

## WiFi (optional)

The BCM4364 WiFi chip requires firmware extracted from macOS. Since the server uses Ethernet, WiFi is optional. To set it up post-install, see the [T2 Linux WiFi guide](https://wiki.t2linux.org/guides/wifi/).

## Thermal note

MacBook Pros vent through the hinge. If running with the lid closed, consider keeping it slightly open for better airflow, or use more aggressive fan curves in the t2fanrd config.

## CI

A GitHub Actions workflow builds the ISO on every pull request. The built ISO is available as an artifact (7-day retention).
