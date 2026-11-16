# Jellyfin Rootless Podman Quadlet Bootstrapper

An interactive, cross-distro bootstrap script that deploys **Jellyfin** using **rootless Podman** and native **systemd Quadlets**, paired with a flexible single- or two-stage automated backup pipeline designed for effortless disaster recovery and bare-metal rebuilds.

## Features
- **Cross-Distro Gatekeeper:** Verifies rootless execution, `systemd`, `/etc/subuid` ranges, and Podman `>= 4.4` across Debian 13+, Ubuntu 24.04+, Fedora, RHEL/Rocky/Alma, openSUSE, and Arch.
- **Side-by-Side Instance Support:** Prompts for a custom container/Quadlet name (e.g., `jellyfin` or `jellyfin-test`) so you can run multiple isolated instances on the same host.
- **Multi-Storage Media Detection:** Automatically detects **Local** (`ext4`, `btrfs`, `xfs`, `zfs`), **Samba/SMB** (`cifs`), and **NFS** media paths—applying `:Z` SELinux labels only on local drives and prompting manually if a filesystem type is unrecognized.
- **Hardware & Priority Controls:** Optional `/dev/dri` GPU transcoding (`GroupAdd=keep-groups`), host-matched `Timezone=local`, and low CPU/I/O scheduling weights (`Nice=10`, `CPUWeight=50`) so background scans never lag the host.
- **Flexible Single- or Two-Stage Backups:**
  - **Stage 1 (`02:00 AM`):** Cold-stop config snapshot (`<name>_YYYY-MM-DD_b0001.tar.gz`) written via local `.tmp` staging (keeping `/tmp` RAM safe). Automatically respects manually stopped containers so backups never wake an instance you stopped intentionally.
  - **Stage 2 (`02:30 AM`, Optional):** Centralized `rsync --ignore-existing` push to an NFS, SMB, or secondary local drive with mount-point guards, a **2 GB free-space safety check**, and count-based rotation (default **5** backups on network shares, **2** on local drives). Single-drive users can skip Stage 2 completely.
- **Self-Documenting Recovery:** Generates `HOW_TO_RESTORE.txt` directly inside both the local staging and Stage 2 backup parent folders.
- **Built-In Uninstaller (`--uninstall`):** Cleanly stops and removes any instance's Quadlet, systemd service, and backup timers with zero orphaned timers left behind.

## Quick Start

Run the commands below in your terminal as your **standard user** (do not run with `sudo`):

```bash
git clone https://github.com
cd podman-jellyfin-quadlet
chmod +x bootstrap-jellyfin.sh
./bootstrap-jellyfin.sh --keep
```

> **Note:** Pass `--keep` to retain the script in your folder (recommended so you can use `--uninstall` later). Without `--keep`, the script offers to delete itself once Jellyfin responds.

## Verify Your Backup Pipeline

Once the Jellyfin web UI responds, trigger a manual test run of your backup pipeline (replace `jellyfin` if you chose a custom instance name):

```bash
# Test Stage 1 (local config archive)
systemctl --user start jellyfin-backup.service

# Test Stage 2 (only if you enabled Stage 2 NAS/secondary drive sync)
systemctl --user start nas-backup-sync.service
```

## Uninstall / Teardown

The uninstaller is built directly into the main script. It stops the container, removes all `.container`, `.service`, and `.timer` units, disables the shared Stage 2 timer if no other instances remain, and asks separately before deleting your config or backup folders:

```bash
cd podman-jellyfin-quadlet
./bootstrap-jellyfin.sh --uninstall
```

To target a specific named instance directly:

```bash
./bootstrap-jellyfin.sh --uninstall jellyfin-test
```

## Changelog

### v1.4.0
- Added built-in `--uninstall [instance_name]` mode and retired standalone `uninstall-jellyfin.sh`.
- Added **Samba/SMB (`cifs`)** and **local storage** auto-detection alongside NFS (plus a 1–3 manual fallback prompt).
- Added optional **Single-Stage (local-only)** backup mode for single-drive hosts.
- Switched Stage 2 retention from day-based to count-based (default **5** on NAS, **2** on local drives) and reduced local staging retention to **1** when Stage 2 is active.
- Moved temporary backup creation from `/tmp` to `~/backups/staging/.tmp` and added a **2 GB minimum free-space guard** before Stage 2 sync.
- Added `WAS_RUNNING` check so scheduled backups never restart a manually stopped container.
- Added `Timezone=local` to the Quadlet template and LAN firewall guidance upon completion.
