# easy-jellyfin-setup (`v2.0.0-beta`)

A beginner-friendly, interactive Bash installer for setting up **Jellyfin Media Server** on Linux—supporting both **Rootless Podman Containers (Quadlets)** and **Native Linux Package Installs** with smart network storage detection and safe on-demand backups.

> **Status:** `v2.0.0-beta` — Looking for the previous `v1.4.1` release with automated two-stage `systemd` backup timers? -(not recommended for the typical home user)- Grab it anytime from the [`v1.4.1` tag](https://github.com) or the `archive-v1.4.1` branch (not recommended for the typical home user).

---

## Features

* **Guided Mode Choice (Explained in Plain English):**
  * **Option 1 — Rootless Podman Container (Recommended):** Runs Jellyfin in an isolated, rootless container managed natively by `systemd` Quadlets. Keeps your host OS clean, makes upgrades effortless, and works identically across Debian, Ubuntu, Mint, Fedora, RHEL/Rocky/Alma, openSUSE, and Arch.
  * **Option 2 — Native Linux Package Install:** Installs Jellyfin directly via `apt` (`extrepo` on Debian/Ubuntu/Mint) or `dnf` (RPM Fusion on Fedora/RHEL/Rocky/Alma) and configures read-only media ACLs automatically.
* **Smart Media Storage Detection (`Local`, `NFS`, and `Samba/SMB`):**
  * Automatically lists active `NFS` and `Samba/SMB` shares on your machine.
  * Applies SELinux `:Z` volume labels for local drives (`ext4`, `btrfs`, `xfs`, `zfs`) and omits `:Z` automatically on network shares so mounts never fail.
  * Warns against top-level mount points to protect your Jellyfin library metadata if an external or network drive temporarily disconnects.
* **Optional Hardware Transcoding (`/dev/dri`):**
  * Detects `/dev/dri` automatically and configures GPU passthrough (`GroupAdd=keep-groups` in container mode, or `render`/`video` group membership in native mode).
* **Zero Background Timers + Safe On-Demand Backups (`--backup`):**
  * No background cron jobs or NAS lockups. Run `./easy-jellyfin-setup.sh --backup` anytime to cleanly pause Jellyfin (preventing SQLite database corruption), save a dated `.tar.gz` archive to `~/backups/jellyfin/`, and resume the service.
* **Clean Unified Uninstaller (`--uninstall`):**
  * Removes either a Podman Quadlet or a native package install cleanly while leaving your media library untouched.
* **Contributor-Friendly Source Code:**
  * Includes `# [NOTE]` annotations throughout the script explaining *why* each check, permission, and Podman flag is used.

---

## Before You Install: Know Your Media Folder Path

One of the biggest headaches for newcomers is figuring out how to pass local drives, NAS shares, or external mounts into a container so Jellyfin can actually see them. **`easy-jellyfin-setup` handles all of the Podman volume mapping and network share flags (`NFS`, `Samba/SMB`, and local `:Z` labels) for you automatically**—you just need to tell it the exact host path where your media lives.

Before running the installer, find the **specific subfolder** that actually contains your movies, shows, or music (for example, `/mnt/nas/media` or `/media/username/Drive/Movies`) rather than a top-level mount point (`/mnt/nas` or `/media/username/Drive`).

* **Why a subfolder matters:** If an external USB drive or network share ever disconnects or takes a moment to mount at boot, pointing Jellyfin at a top-level mount directory makes Jellyfin see an empty folder—which can cause it to wipe your library metadata and watch history. Pointing to a subfolder inside the mount prevents that completely.

## Quick Start

---

### 1. Download and Run
Run the installer as your **standard user** (do **not** run as `root` or with `sudo`):

```bash
curl -fsSL https://raw.githubusercontent.com/deadlinkuser/easy-jellyfin-setup/main/easy-jellyfin-setup.sh -o ~/easy-jellyfin-setup.sh
chmod +x ~/easy-jellyfin-setup.sh
~/easy-jellyfin-setup.sh --keep
```

### 2. Complete the Browser Setup Wizard
Once the script finishes, open the printed local URL in your browser:
* **Local Machine:** `http://127.0.0.1:8096`
* **Other Devices on Your Network:** `http://<your-server-ip>:8096`
* **Media Folder Path Inside Jellyfin:** Select `/media` (Container mode) or your host media path (Native mode).

---

## Everyday Management Commands

| Task | Command |
| :--- | :--- |
| **Create a safe local backup** | `~/easy-jellyfin-setup.sh --backup` |
| **Uninstall Jellyfin cleanly** | `~/easy-jellyfin-setup.sh --uninstall` |
| **Stop / Start (Container mode)** | `systemctl --user stop jellyfin.service` / `systemctl --user start jellyfin.service` |
| **Stop / Start (Native mode)** | `sudo systemctl stop jellyfin.service` / `sudo systemctl start jellyfin.service` |
| **View container logs** | `journalctl --user -u jellyfin.service -f` |
| **Clean unused container images** | `podman image prune -f` |

---

## Backing Up & Restoring

* **Creating a Backup:** Run `~/easy-jellyfin-setup.sh --backup`. Your archive is saved to `~/backups/jellyfin/jellyfin_YYYY-MM-DD_HHMM.tar.gz` (excluding disposable cache/transcode folders). You can copy that `.tar.gz` file to your NAS, USB drive, or cloud storage whenever you like.
* **Restoring a Container Backup:**
  ```bash
  systemctl --user stop jellyfin.service
  mv ~/containers/jellyfin/config ~/containers/jellyfin/config.old
  tar -xzf /path/to/jellyfin_YYYY-MM-DD_HHMM.tar.gz -C ~/containers/jellyfin/
  systemctl --user start jellyfin.service
  ```
* A tailored `HOW_TO_RESTORE.txt` file is also generated automatically inside `~/backups/jellyfin/`.

---

## Feedback & Contributions

This project is currently in **`v2.0.0-beta`**. If you run into a quirk on your distro, have an idea to make the prompts clearer for newcomers, or want to suggest an improvement, please open an issue or discussion:
* **Feedback & Issues:** https://github.com
