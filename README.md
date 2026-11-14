# Jellyfin Rootless Podman Quadlet Bootstrapper

An interactive, cross-distro bootstrap script that deploys **Jellyfin** using **rootless Podman** and native **systemd Quadlets**, paired with a two-stage automated backup pipeline designed for effortless disaster recovery and bare-metal rebuilds.

## Features
- **Cross-Distro Gatekeeper:** Verifies rootless execution, `systemd`, `/etc/subuid` ranges, and Podman `>= 4.4` across Debian 13+, Ubuntu 24.04+, Fedora, RHEL/Rocky/Alma, openSUSE, and Arch.
- **Smart Storage & NFS Handling:** Automatically detects NFS media mounts (omitting `:Z` labels to prevent mount errors and checking SELinux `virt_use_nfs` where applicable).
- **Hardware & Priority Controls:** Optional `/dev/dri` GPU transcoding (`GroupAdd=keep-groups`) and low CPU/I/O scheduling weights (`Nice=10`, `CPUWeight=50`) so background scans never lag the host.
- **Two-Stage Automated Backups:**
  - **Stage 1 (`02:00 AM`):** Atomic cold-stop config snapshot (`jellyfin_YYYY-MM-DD_b0001.tar.gz`) to `~/backups/staging/jellyfin/`, keeping the **2 newest archives** locally and pruning old Podman images.
  - **Stage 2 (`02:30 AM`):** Centralized `rsync --ignore-existing` push to an NFS/ZFS backup mount with active mount-point guards and configurable retention (default `30` days).
- **Self-Documenting Recovery:** Generates `HOW_TO_RESTORE.txt` directly inside both the local staging and NAS backup parent folders.
- **Optional Self-Cleanup:** Verifies port `8096` responds and offers to remove the bootstrap script once setup is confirmed (pass `--keep` to retain).

## Quick Start

```bash
git clone https://github.com
cd podman-jellyfin-quadlet
./bootstrap-jellyfin.sh --keep
```
