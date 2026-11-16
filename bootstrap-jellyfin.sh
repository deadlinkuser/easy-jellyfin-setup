#!/usr/bin/env bash
# ==============================================================================
# Jellyfin Rootless Podman Quadlet & Two-Stage Backup Bootstrapper (v1.4)
# ==============================================================================
# Features:
#   - Cross-distro OS & Podman >= 4.4 gatekeeper (/etc/os-release)
#   - Rootless user check, /etc/subuid validation & smart loginctl linger prompt
#   - Built-in --uninstall [instance_name] teardown with zero hanging timers
#   - Configurable Instance/Container Name (supports upgrades & side-by-side)
#   - Multi-storage detection: Local (:Z), Samba/SMB, and NFS + manual fallback
#   - Optional GPU transcoding (/dev/dri + GroupAdd=keep-groups), Timezone=local,
#     and CPU/IO priority controls
#   - Stage 1 (02:00): Cold-stop config backup via local .tmp staging +
#     WAS_RUNNING check so manually stopped containers stay stopped
#   - Stage 2 (02:30, Optional): Centralized rsync to NAS/SMB/local drive with
#     mount guard, 2 GB free-space check, and count-based rotation (default 5/2)
#   - Generates HOW_TO_RESTORE.txt in both local staging and Stage 2 backup roots
#   - Verifies live HTTP response and optionally self-deletes
# ==============================================================================

set -euo pipefail

# --- Formatting Helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local reply
    if [[ "$default" == "Y" ]]; then
        read -rp "$(echo -e "${BOLD}${prompt} [Y/n]: ${NC}")" reply
        reply="${reply:-Y}"
    else
        read -rp "$(echo -e "${BOLD}${prompt} [y/N]: ${NC}")" reply
        reply="${reply:-N}"
    fi
    [[ "$reply" =~ ^[Yy]$ ]]
}

# --- Argument Parsing ---
KEEP_SCRIPT=false
UNINSTALL_MODE=false
UNINSTALL_TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep|--no-self-delete)
            KEEP_SCRIPT=true
            shift
            ;;
        --uninstall)
            UNINSTALL_MODE=true
            if [[ -n "${2:-}" && ! "${2:-}" =~ ^- ]]; then
                UNINSTALL_TARGET="$2"
                shift
            fi
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--keep] [--uninstall [instance_name]]"
            echo "  --keep                      Do not offer to delete this script after verification."
            echo "  --uninstall [instance_name] Cleanly stop and remove a Jellyfin instance and its timers."
            exit 0
            ;;
        *)
            err "Unknown option: $1 (use --help for usage)"
            exit 1
            ;;
    esac
done

# ==============================================================================
# 0. BUILT-IN UNINSTALLER (--uninstall)
# ==============================================================================
if [[ "$UNINSTALL_MODE" == true ]]; then
    echo -e "\n${BOLD}=== Jellyfin Rootless Podman Quadlet Uninstaller ===${NC}\n"

    if [[ "$EUID" -eq 0 ]]; then
        err "Do NOT run --uninstall as root or with sudo. Run as your standard user."
        exit 1
    fi

    QUADLET_DIR="${HOME}/.config/containers/systemd"
    SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

    if [[ -z "$UNINSTALL_TARGET" ]]; then
        read -rp "$(echo -e "${BOLD}Instance name to uninstall [jellyfin]: ${NC}")" UNINSTALL_TARGET
        UNINSTALL_TARGET="${UNINSTALL_TARGET:-jellyfin}"
    fi

    APP_NAME="$UNINSTALL_TARGET"
    APP_DIR="${HOME}/containers/${APP_NAME}"
    STAGING_APP="${HOME}/backups/staging/${APP_NAME}"

    if [[ ! -f "${QUADLET_DIR}/${APP_NAME}.container" && \
          ! -f "${SYSTEMD_USER_DIR}/${APP_NAME}-backup.timer" && \
          ! -d "$APP_DIR" ]]; then
        warn "No Quadlet, backup timer, or folder found for '${APP_NAME}'."
        exit 0
    fi

    echo "This will stop and remove:"
    echo "  - Container service: ${APP_NAME}.service"
    echo "  - Quadlet file:      ${QUADLET_DIR}/${APP_NAME}.container"
    echo "  - Stage 1 backup:    ${APP_NAME}-backup.timer & .service"
    echo ""
    if ! ask_yes_no "Proceed with uninstalling '${APP_NAME}' units and timers?" "N"; then
        info "Uninstall cancelled. Nothing was changed."
        exit 0
    fi

    info "Stopping and disabling ${APP_NAME} timers and container..."
    systemctl --user disable --now "${APP_NAME}-backup.timer" 2>/dev/null || true
    systemctl --user stop "${APP_NAME}-backup.service" 2>/dev/null || true
    systemctl --user stop "${APP_NAME}.service" 2>/dev/null || true

    rm -f \
        "${QUADLET_DIR}/${APP_NAME}.container" \
        "${SYSTEMD_USER_DIR}/${APP_NAME}-backup.timer" \
        "${SYSTEMD_USER_DIR}/${APP_NAME}-backup.service"

    REMAINING_TIMERS=$(find "$SYSTEMD_USER_DIR" -maxdepth 1 -name "*-backup.timer" 2>/dev/null | wc -l)
    if [[ "$REMAINING_TIMERS" -eq 0 && -f "${SYSTEMD_USER_DIR}/nas-backup-sync.timer" ]]; then
        info "No other container backup timers remain."
        if ask_yes_no "Disable and remove shared Stage 2 NAS sync timer (nas-backup-sync.timer) too?" "Y"; then
            systemctl --user disable --now nas-backup-sync.timer 2>/dev/null || true
            systemctl --user stop nas-backup-sync.service 2>/dev/null || true
            rm -f \
                "${SYSTEMD_USER_DIR}/nas-backup-sync.timer" \
                "${SYSTEMD_USER_DIR}/nas-backup-sync.service" \
                "${HOME}/containers/shared-scripts/nas-backup-sync.sh"
            ok "Removed shared Stage 2 NAS sync timer and script."
        fi
    fi

    systemctl --user daemon-reload
    systemctl --user reset-failed 2>/dev/null || true
    ok "All systemd units and timers for '${APP_NAME}' have been cleanly removed."

    echo ""
    if [[ -d "$APP_DIR" ]]; then
        if ask_yes_no "Delete container config & cache directory (${APP_DIR})? (No = keep data)" "N"; then
            rm -rf "$APP_DIR"
            ok "Deleted ${APP_DIR}."
        else
            info "Preserved ${APP_DIR} on disk."
        fi
    fi

    if [[ -d "$STAGING_APP" ]]; then
        if ask_yes_no "Delete local staging backups (${STAGING_APP})?" "N"; then
            rm -rf "$STAGING_APP"
            rm -f "${HOME}/backups/staging/.${APP_NAME}-backup.count"
            ok "Deleted ${STAGING_APP}."
        else
            info "Preserved ${STAGING_APP} on disk."
        fi
    fi

    ok "Uninstall of '${APP_NAME}' complete! (Your media files and NAS backups were untouched.)"
    exit 0
fi

# ==============================================================================
# 1. HARD BLOCKERS & OS GATEKEEPER
# ==============================================================================
echo -e "\n${BOLD}=== Jellyfin Rootless Podman Quadlet Bootstrapper ===${NC}\n"

if [[ "$EUID" -eq 0 ]]; then
    err "Do NOT run this script as root or with sudo."
    err "This architecture uses rootless Podman and systemd --user units."
    err "Please log in as your standard user and run: ./$(basename "$0")"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    err "systemd (systemctl) was not found on this system."
    err "Podman Quadlets and user timers require a systemd-based distribution."
    exit 1
fi

OS_ID="unknown"
OS_VERSION="0"
OS_PRETTY="Unknown Linux"
OS_LIKE=""

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-0}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
    OS_LIKE="${ID_LIKE:-}"
fi

info "Detected Operating System: ${BOLD}${OS_PRETTY}${NC}"

OS_STATUS="untested"
PKG_HINT="Install podman (>= 4.4), rsync, tar, and curl using your package manager."

case "$OS_ID" in
    debian)
        PKG_HINT="sudo apt update && sudo apt install -y podman rsync tar curl"
        if awk "BEGIN {exit !($OS_VERSION >= 13)}"; then OS_STATUS="verified"; else OS_STATUS="old"; fi
        ;;
    ubuntu|pop|linuxmint)
        PKG_HINT="sudo apt update && sudo apt install -y podman rsync tar curl"
        if [[ "$OS_ID" == "ubuntu" ]] && awk "BEGIN {exit !($OS_VERSION >= 24.04)}"; then
            OS_STATUS="verified"
        else
            OS_STATUS="old"
        fi
        ;;
    fedora)
        PKG_HINT="sudo dnf install -y podman rsync tar curl"
        if awk "BEGIN {exit !($OS_VERSION >= 38)}"; then OS_STATUS="verified"; else OS_STATUS="old"; fi
        ;;
    rhel|rocky|almalinux|centos)
        PKG_HINT="sudo dnf install -y podman rsync tar curl"
        if awk "BEGIN {exit !($OS_VERSION >= 9)}"; then OS_STATUS="verified"; else OS_STATUS="old"; fi
        ;;
    opensuse-tumbleweed|opensuse-leap|sles)
        PKG_HINT="sudo zypper install -y podman rsync tar curl"
        OS_STATUS="verified"
        ;;
    arch|endeavouros|manjaro)
        PKG_HINT="sudo pacman -S --needed podman rsync tar curl"
        OS_STATUS="verified"
        ;;
    *)
        if [[ "$OS_LIKE" == *"debian"* ]]; then
            PKG_HINT="sudo apt update && sudo apt install -y podman rsync tar curl"
        elif [[ "$OS_LIKE" == *"rhel"* || "$OS_LIKE" == *"fedora"* ]]; then
            PKG_HINT="sudo dnf install -y podman rsync tar curl"
        fi
        OS_STATUS="untested"
        ;;
esac

if [[ "$OS_STATUS" == "verified" ]]; then
    ok "Verified compatible OS family."
elif [[ "$OS_STATUS" == "old" ]]; then
    warn "Detected '${OS_PRETTY}', which may ship Podman older than v4.4 (required for Quadlets)."
    if ! ask_yes_no "Continue anyway and check live Podman version?" "N"; then
        info "Aborted safely. No changes were made."
        exit 0
    fi
else
    warn "Detected '${OS_PRETTY}', which has not been explicitly tested with this script."
    if ! ask_yes_no "Proceed anyway at your own risk?" "N"; then
        info "Aborted safely. No changes were made."
        exit 0
    fi
fi

# ==============================================================================
# 2. DEPENDENCY, PODMAN VERSION, SUBUID & LINGER CHECKS
# ==============================================================================
MISSING_TOOLS=()
for cmd in podman rsync tar curl loginctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_TOOLS+=("$cmd")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    err "Missing required tools: ${MISSING_TOOLS[*]}"
    info "Install them with: ${BOLD}${PKG_HINT}${NC}"
    exit 1
fi

PODMAN_VER=$(podman --version | awk '{print $3}')
MIN_PODMAN="4.4.0"
if [[ "$(printf '%s\n' "$MIN_PODMAN" "$PODMAN_VER" | sort -V | head -n1)" != "$MIN_PODMAN" ]]; then
    err "Podman v${PODMAN_VER} detected. Quadlets require Podman >= ${MIN_PODMAN}."
    exit 1
fi
ok "Podman v${PODMAN_VER} meets Quadlet requirements (>= ${MIN_PODMAN})."

if ! grep -q "^${USER}:" /etc/subuid 2>/dev/null || ! grep -q "^${USER}:" /etc/subgid 2>/dev/null; then
    err "User '${USER}' lacks subordinate UID/GID ranges in /etc/subuid or /etc/subgid."
    info "Fix this as root with:"
    echo "  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${USER}"
    exit 1
fi
ok "Rootless subuid/subgid mappings verified for '${USER}'."

LINGER_STATE=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo "no")
if [[ "$LINGER_STATE" == "yes" ]]; then
    ok "User lingering is already enabled for '${USER}'."
else
    echo ""
    warn "User lingering is currently DISABLED for '${USER}'."
    echo "  Why this matters: Without lingering, systemd stops your rootless"
    echo "  containers and timers when you log out, and won't auto-start them"
    echo "  after a reboot until you manually log in."
    if ask_yes_no "Enable user lingering now (loginctl enable-linger ${USER})?" "Y"; then
        if loginctl enable-linger "$USER" 2>/dev/null || sudo loginctl enable-linger "$USER"; then
            ok "User lingering enabled."
        else
            warn "Could not enable linger automatically. Run manually later: sudo loginctl enable-linger ${USER}"
        fi
    else
        warn "Skipping linger. Jellyfin will only run while '${USER}' is logged in."
    fi
fi

# ==============================================================================
# 3. INTERACTIVE INSTANCE NAME, PATHS & HARDWARE CONFIGURATION
# ==============================================================================
echo -e "\n${BOLD}--- Instance, Storage, Backup & Hardware Prompts ---${NC}"

QUADLET_DIR="${HOME}/.config/containers/systemd"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"

# Prompt 0: Container / Instance Name (supports upgrades & side-by-side installs)
DEFAULT_APP_NAME="jellyfin"
while true; do
    read -rp "$(echo -e "${BOLD}Container / Quadlet instance name [${DEFAULT_APP_NAME}]: ${NC}")" APP_NAME
    APP_NAME="${APP_NAME:-$DEFAULT_APP_NAME}"

    if [[ ! "$APP_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        err "Invalid name '${APP_NAME}'. Use lowercase letters, numbers, hyphens (-), or underscores (_)."
        continue
    fi

    if [[ -f "${QUADLET_DIR}/${APP_NAME}.container" || -d "${HOME}/containers/${APP_NAME}" ]]; then
        warn "An existing '${APP_NAME}' setup was found on this host."
        echo "  * Answer 'Y' to replace/update the Quadlet & backup timers in place"
        echo "    (your existing ~/containers/${APP_NAME}/config data will be kept)."
        echo "  * Answer 'N' to enter a different name (e.g., '${APP_NAME}-test') for a"
        echo "    separate side-by-side instance."
        if ! ask_yes_no "Replace/update existing '${APP_NAME}' units and timers?" "N"; then
            continue
        fi
    fi
    ok "Using instance name: ${BOLD}${APP_NAME}${NC}"
    break
done

# Prompt 1: Media Path
ACTIVE_NET_MOUNTS=$(findmnt -rn -t nfs,nfs4,cifs,smb3 -o TARGET,FSTYPE 2>/dev/null || true)
if [[ -n "$ACTIVE_NET_MOUNTS" ]]; then
    echo ""
    info "Active network mounts detected on this host:"
    while IFS= read -r line; do
        echo "    -> $line"
    done <<< "$ACTIVE_NET_MOUNTS"
fi

DEFAULT_MEDIA="/mnt/media/data"
while true; do
    echo ""
    read -rp "$(echo -e "${BOLD}Host path to your Media directory [${DEFAULT_MEDIA}]: ${NC}")" MEDIA_PATH
    MEDIA_PATH="${MEDIA_PATH:-$DEFAULT_MEDIA}"
    MEDIA_PATH="${MEDIA_PATH%/}"

    if [[ ! -d "$MEDIA_PATH" ]]; then
        warn "Directory '${MEDIA_PATH}' does not exist."
        if ask_yes_no "Create '${MEDIA_PATH}' now?" "N"; then
            mkdir -p "$MEDIA_PATH" || { err "Failed to create ${MEDIA_PATH}. Check permissions."; continue; }
        else
            continue
        fi
    fi

    if [[ ! -r "$MEDIA_PATH" ]]; then
        err "Current user '${USER}' cannot read '${MEDIA_PATH}'. Fix permissions and retry."
        continue
    fi

    if mountpoint -q "$MEDIA_PATH"; then
        warn "'${MEDIA_PATH}' is a top-level mount point."
        warn "Using a subfolder (e.g., ${MEDIA_PATH}/media) prevents Jellyfin from"
        warn "wiping your library metadata if an NFS/external drive disconnects."
        if ! ask_yes_no "Use '${MEDIA_PATH}' anyway (or 'N' to enter a subfolder)?" "N"; then
            continue
        fi
    fi
    break
done

MEDIA_FSTYPE=$(stat -f -c %T "$MEDIA_PATH" 2>/dev/null || echo "unknown")
MEDIA_VOL_OPTS=""

case "$MEDIA_FSTYPE" in
    nfs*)
        ok "Detected NFS network filesystem (${MEDIA_FSTYPE}) -> omitting :Z label."
        if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
            if command -v getsebool >/dev/null 2>&1 && ! getsebool virt_use_nfs 2>/dev/null | grep -q "on$"; then
                warn "SELinux is Enforcing and 'virt_use_nfs' is OFF!"
                warn "Run: sudo setsebool -P virt_use_nfs 1"
            fi
        fi
        ;;
    cifs|smb*)
        ok "Detected Samba/SMB network share (${MEDIA_FSTYPE}) -> omitting :Z label."
        warn "Tip: Ensure your SMB mount in /etc/fstab includes 'uid=$(id -u),gid=$(id -g)'"
        warn "     so rootless Jellyfin can read your media files cleanly."
        ;;
    ext2/ext3|ext4|btrfs|xfs|zfs|tmpfs|overlayfs)
        MEDIA_VOL_OPTS=":Z"
        ok "Detected local filesystem (${MEDIA_FSTYPE}) -> using :Z label."
        ;;
    *)
        warn "Could not auto-identify filesystem type ('${MEDIA_FSTYPE}') for '${MEDIA_PATH}'."
        echo "How is this media directory stored?"
        echo "  1) Local drive (ext4, btrfs, xfs, zfs)  [uses :Z label]"
        echo "  2) Samba / SMB network share (cifs)     [omits :Z label]"
        echo "  3) NFS network share                    [omits :Z label]"
        read -rp "$(echo -e "${BOLD}Select storage type [1-3, default 1]: ${NC}")" STORAGE_CHOICE
        case "${STORAGE_CHOICE:-1}" in
            2)
                MEDIA_FSTYPE="smb (manual)"
                ok "Configured for Samba/SMB -> omitting :Z label."
                ;;
            3)
                MEDIA_FSTYPE="nfs (manual)"
                ok "Configured for NFS -> omitting :Z label."
                ;;
            *)
                MEDIA_FSTYPE="local (manual)"
                MEDIA_VOL_OPTS=":Z"
                ok "Configured for local storage -> using :Z label."
                ;;
        esac
        ;;
esac

# Prompt 2: Stage 2 Backup Destination (Optional for single-drive / local-only users)
ENABLE_STAGE2=false
BACKUP_IS_NETWORK=false
NAS_BACKUP_ROOT=""
MOUNT_ROOT="/"

echo ""
if ask_yes_no "Enable Stage 2 off-site/NAS backup sync (recommended if you have a NAS or second drive)?" "Y"; then
    ENABLE_STAGE2=true
    DEFAULT_NAS_BACKUP="/mnt/nas/container-backups"
    EXISTING_SYNC_SCRIPT="${HOME}/containers/shared-scripts/nas-backup-sync.sh"
    if [[ -f "$EXISTING_SYNC_SCRIPT" ]]; then
        DETECTED_NAS=$(grep -E '^NAS_BACKUP_ROOT=' "$EXISTING_SYNC_SCRIPT" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
        [[ -n "$DETECTED_NAS" ]] && DEFAULT_NAS_BACKUP="$DETECTED_NAS"
    fi

    if [[ -n "$ACTIVE_NET_MOUNTS" ]]; then
        echo ""
        info "Active network mounts available on this host:"
        while IFS= read -r line; do
            echo "    -> $line"
        done <<< "$ACTIVE_NET_MOUNTS"
    fi

    BACKUP_IS_NETWORK=true
    while true; do
        echo ""
        read -rp "$(echo -e "${BOLD}Host path to Stage 2 backup parent directory [${DEFAULT_NAS_BACKUP}]: ${NC}")" NAS_BACKUP_ROOT
        NAS_BACKUP_ROOT="${NAS_BACKUP_ROOT:-$DEFAULT_NAS_BACKUP}"
        NAS_BACKUP_ROOT="${NAS_BACKUP_ROOT%/}"

        CHECK_DIR="$NAS_BACKUP_ROOT"
        while [[ ! -e "$CHECK_DIR" && "$CHECK_DIR" != "/" ]]; do
            CHECK_DIR="$(dirname "$CHECK_DIR")"
        done

        BACKUP_FSTYPE=$(stat -f -c %T "$CHECK_DIR" 2>/dev/null || echo "unknown")
        MOUNT_ROOT=$(findmnt -T "$CHECK_DIR" -no TARGET 2>/dev/null || echo "/")

        case "$BACKUP_FSTYPE" in
            nfs*|cifs|smb*)
                BACKUP_IS_NETWORK=true
                ok "Detected network share (${BACKUP_FSTYPE}) on mount '${MOUNT_ROOT}'."
                ;;
            *)
                if [[ "$MOUNT_ROOT" == "/" ]]; then
                    warn "'${NAS_BACKUP_ROOT}' resolves to your local OS drive (/), not a mounted share."
                    echo "How would you like to proceed?"
                    echo "  1) Exit now so I can mount my network share (NFS/SMB) first"
                    echo "  2) Re-enter a different path (e.g., I made a typo or want a detected mount above)"
                    echo "  3) Use this local folder intentionally (skips mount check, keeps 2 backups)"
                    read -rp "$(echo -e "${BOLD}Select [1-3, default 1]: ${NC}")" BACKUP_LOC_CHOICE
                    case "${BACKUP_LOC_CHOICE:-1}" in
                        2)
                            continue
                            ;;
                        3)
                            BACKUP_IS_NETWORK=false
                            MOUNT_ROOT="/"
                            warn "Using local storage for Stage 2 backups (protects against config corruption, not drive failure)."
                            ;;
                        *)
                            info "Aborted safely. Mount your NFS/SMB share first, then re-run $(basename "$0")."
                            exit 0
                            ;;
                    esac
                else
                    BACKUP_IS_NETWORK=false
                    ok "Detected separate local mount '${MOUNT_ROOT}' (${BACKUP_FSTYPE})."
                fi
                ;;
        esac

        if ! mkdir -p "${NAS_BACKUP_ROOT}/${APP_NAME}" 2>/dev/null; then
            err "Permission denied creating '${NAS_BACKUP_ROOT}/${APP_NAME}'."
            info "On your host, run: sudo mkdir -p '${NAS_BACKUP_ROOT}' && sudo chown -R ${USER}:${USER} '${NAS_BACKUP_ROOT}'"
            if ask_yes_no "Retry after fixing permissions?" "Y"; then
                continue
            else
                exit 1
            fi
        fi

        touch "${NAS_BACKUP_ROOT}/.backup-target-verified"
        ok "Stage 2 backup target verified and writable."
        break
    done
else
    info "Stage 2 NAS sync skipped. Backups will stay in local staging (${HOME}/backups/staging/${APP_NAME})."
fi

# Prompt 3: Port Selection (displays default & checks if occupied)
while true; do
    echo ""
    read -rp "$(echo -e "${BOLD}Host HTTP port for ${APP_NAME} web UI [8096]: ${NC}")" JELLYFIN_PORT
    JELLYFIN_PORT="${JELLYFIN_PORT:-8096}"
    if [[ ! "$JELLYFIN_PORT" =~ ^[0-9]+$ ]] || (( JELLYFIN_PORT < 1024 || JELLYFIN_PORT > 65535 )); then
        err "Please enter a valid unprivileged port number (1024-65535)."
        continue
    fi
    if ss -tln 2>/dev/null | grep -qE ":${JELLYFIN_PORT} "; then
        warn "Port ${JELLYFIN_PORT} is ALREADY in use on this host!"
        if ! ask_yes_no "Use port ${JELLYFIN_PORT} anyway?" "N"; then
            continue
        fi
    fi
    break
done

# Prompt 4: GPU Hardware Transcoding (with 8th Gen+ guidance & official docs link)
ENABLE_GPU=false
if [[ -d /dev/dri ]]; then
    echo ""
    echo -e "${BOLD}Hardware Acceleration (/dev/dri) Guidance:${NC}"
    echo "  * Enable (Y): Offloads 4K/HEVC transcoding to your GPU so streams"
    echo "    do not max out your CPU. Best on Intel 8th Gen+ (Coffee Lake or"
    echo "    newer), AMD Ryzen/Radeon (VCN), or supported NVIDIA GPUs."
    echo "  * Skip (n): Older CPUs (7th Gen Intel or earlier, which often hit"
    echo "    VA-API/tone-mapping quirks), headless VMs without GPU passthrough,"
    echo "    or libraries that Direct Play natively."
    echo "  * Best source for Jellyfin hardware acceleration docs:"
    echo "    https://jellyfin.org"
    if ask_yes_no "GPU device (/dev/dri) detected. Enable hardware transcoding passthrough?" "Y"; then
        ENABLE_GPU=true
        USER_GROUPS=$(id -nG "$USER")
        MISSING_GPU_GROUPS=()
        for grp in render video; do
            if getent group "$grp" >/dev/null 2>&1 && [[ ! " $USER_GROUPS " =~ " $grp " ]]; then
                MISSING_GPU_GROUPS+=("$grp")
            fi
        done
        if [[ ${#MISSING_GPU_GROUPS[@]} -gt 0 ]]; then
            warn "User '${USER}' is not in group(s): ${MISSING_GPU_GROUPS[*]}"
            warn "GPU transcoding may fail until you run:"
            echo "  sudo usermod -aG $(IFS=,; echo "${MISSING_GPU_GROUPS[*]}") ${USER}"
            echo "  (Note: requires a logout/reboot to refresh group membership)"
        else
            ok "User '${USER}' has required GPU group memberships."
        fi
    fi
fi

# Prompt 5: CPU & Disk I/O Priority
LOW_PRIORITY=false
echo ""
if ask_yes_no "Set lower CPU & I/O priority (Nice=10, CPUWeight=50) so scans/transcodes never lag the host?" "Y"; then
    LOW_PRIORITY=true
fi

# Prompt 6: Backup Retention Count (5 for network NAS, 2 for local drive/staging)
if [[ "$ENABLE_STAGE2" == true && "$BACKUP_IS_NETWORK" == true ]]; then
    DEFAULT_KEEP_NAS=5
else
    DEFAULT_KEEP_NAS=2
fi

echo ""
if [[ "$ENABLE_STAGE2" == true ]]; then
    read -rp "$(echo -e "${BOLD}Max backup archives to keep per container on Stage 2 target [${DEFAULT_KEEP_NAS}]: ${NC}")" NAS_KEEP_COUNT
else
    read -rp "$(echo -e "${BOLD}Max local staging backup archives to keep [${DEFAULT_KEEP_NAS}]: ${NC}")" NAS_KEEP_COUNT
fi
NAS_KEEP_COUNT="${NAS_KEEP_COUNT:-$DEFAULT_KEEP_NAS}"

# Pre-Install Review Summary
echo -e "\n${BOLD}--- Configuration Summary ---${NC}"
echo "  Instance Name:   ${APP_NAME}"
echo "  Web UI Port:     ${JELLYFIN_PORT}"
echo "  Media Path:      ${MEDIA_PATH} (${MEDIA_FSTYPE})"
if [[ "$ENABLE_STAGE2" == true ]]; then
    echo "  Stage 2 Backup:  ${NAS_BACKUP_ROOT}/${APP_NAME} (Retain: ${NAS_KEEP_COUNT} backups)"
else
    echo "  Stage 2 Backup:  Disabled (Local staging only, retain: ${NAS_KEEP_COUNT} backups)"
fi
echo "  GPU Passthrough: ${ENABLE_GPU}"
echo "  Low CPU/IO Prio: ${LOW_PRIORITY}"
echo ""
if ! ask_yes_no "Proceed with creating directories, Quadlet, and backup timers?" "Y"; then
    info "Aborted safely before making any system changes."
    exit 0
fi

# ==============================================================================
# 4. CREATE DIRECTORY STRUCTURE
# ==============================================================================
info "Creating rootless directory hierarchy in ${HOME} for '${APP_NAME}'..."

APP_DIR="${HOME}/containers/${APP_NAME}"
SHARED_SCRIPTS_DIR="${HOME}/containers/shared-scripts"
STAGING_ROOT="${HOME}/backups/staging"
STAGING_APP="${STAGING_ROOT}/${APP_NAME}"

mkdir -p \
    "$QUADLET_DIR" \
    "$SYSTEMD_USER_DIR" \
    "${APP_DIR}/config" \
    "${APP_DIR}/cache" \
    "${APP_DIR}/scripts" \
    "$SHARED_SCRIPTS_DIR" \
    "$STAGING_APP" \
    "${STAGING_ROOT}/.tmp"

# ==============================================================================
# 5. WRITE QUADLET FILE (~/.config/containers/systemd/)
# ==============================================================================
info "Writing Quadlet unit: ${QUADLET_DIR}/${APP_NAME}.container"

GPU_BLOCK=""
if [[ "$ENABLE_GPU" == true ]]; then
    GPU_BLOCK=$'# Hardware Transcoding (/dev/dri)\nAddDevice=/dev/dri:/dev/dri\nGroupAdd=keep-groups'
fi

PRIORITY_BLOCK=""
if [[ "$LOW_PRIORITY" == true ]]; then
    PRIORITY_BLOCK=$'# Keep host desktop/services responsive during heavy scans/transcodes\nNice=10\nCPUWeight=50\nIOSchedulingPriority=6'
fi

cat > "${QUADLET_DIR}/${APP_NAME}.container" <<EOF
[Unit]
Description=Jellyfin Media Server (${APP_NAME} - Rootless Podman Quadlet)
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/jellyfin/jellyfin:latest
ContainerName=${APP_NAME}
AutoUpdate=registry
Timezone=local

# Networking
PublishPort=${JELLYFIN_PORT}:8096

# Persistent & Disposable Storage
Volume=%h/containers/${APP_NAME}/config:/config:Z
Volume=%h/containers/${APP_NAME}/cache:/cache:Z
Volume=${MEDIA_PATH}:/media${MEDIA_VOL_OPTS}

${GPU_BLOCK}

[Service]
Restart=always
TimeoutStartSec=300
${PRIORITY_BLOCK}

[Install]
WantedBy=default.target
EOF

cp "${QUADLET_DIR}/${APP_NAME}.container" "${APP_DIR}/${APP_NAME}.container.backup"

# ==============================================================================
# 6. WRITE STAGE 1 BACKUP SCRIPT & SYSTEMD UNITS (~/.config/systemd/user/)
# ==============================================================================
info "Configuring Stage 1 atomic backup script & timer (02:00 AM daily)..."

cat > "${APP_DIR}/scripts/${APP_NAME}-backup.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME}"
CONFIG_PARENT="\${HOME}/containers/\${APP_NAME}"
STAGING_ROOT="\${HOME}/backups/staging"
STAGING_DIR="\${STAGING_ROOT}/\${APP_NAME}"
TMP_DIR="\${STAGING_ROOT}/.tmp"
COUNT_FILE="\${STAGING_ROOT}/.\${APP_NAME}-backup.count"
KEEP_LOCAL=$( [[ "$ENABLE_STAGE2" == true ]] && echo 1 || echo "$NAS_KEEP_COUNT" )

mkdir -p "\$STAGING_DIR" "\$TMP_DIR"

LAST_NUM=0
if [[ -f "\$COUNT_FILE" ]]; then
    LAST_NUM=\$(cat "\$COUNT_FILE" 2>/dev/null || echo 0)
fi
NEXT_NUM=\$((10#\$LAST_NUM + 1))
printf "%04d" "\$NEXT_NUM" > "\$COUNT_FILE"
SEQ_TAG=\$(printf "b%04d" "\$NEXT_NUM")
DATE_TAG=\$(date +%F)

ARCHIVE_NAME="\${APP_NAME}_\${DATE_TAG}_\${SEQ_TAG}.tar.gz"
TMP_ARCHIVE="\${TMP_DIR}/\${ARCHIVE_NAME}"
FINAL_ARCHIVE="\${STAGING_DIR}/\${ARCHIVE_NAME}"

echo "[\$(date -Is)] Starting backup: \${ARCHIVE_NAME}"

# Check if container was running before backup so we never wake a manually stopped container
WAS_RUNNING=false
if systemctl --user is-active --quiet "\${APP_NAME}.service"; then
    WAS_RUNNING=true
fi

cleanup_on_exit() {
    rm -f "\$TMP_ARCHIVE"
    if [[ "\$WAS_RUNNING" == true ]]; then
        echo "[\$(date -Is)] Restarting \${APP_NAME}.service..."
        systemctl --user start "\${APP_NAME}.service"
    fi
}
trap cleanup_on_exit EXIT

if [[ "\$WAS_RUNNING" == true ]]; then
    echo "[\$(date -Is)] Stopping \${APP_NAME}.service for cold backup..."
    systemctl --user stop "\${APP_NAME}.service"
else
    echo "[\$(date -Is)] \${APP_NAME}.service is already stopped; backing up cold config without restarting."
fi

tar -czf "\$TMP_ARCHIVE" -C "\$CONFIG_PARENT" config
mv "\$TMP_ARCHIVE" "\$FINAL_ARCHIVE"

# Normal completion: restart service only if it was running, then clear the exit trap
if [[ "\$WAS_RUNNING" == true ]]; then
    echo "[\$(date -Is)] Restarting \${APP_NAME}.service..."
    systemctl --user start "\${APP_NAME}.service"
fi
trap - EXIT

echo "[\$(date -Is)] Backup saved to \${FINAL_ARCHIVE} (\$(du -h "\$FINAL_ARCHIVE" | cut -f1))"

mapfile -t OLD_FILES < <(ls -1t "\${STAGING_DIR}/\${APP_NAME}_"*.tar.gz 2>/dev/null | tail -n +\$((KEEP_LOCAL + 1)))
if [[ \${#OLD_FILES[@]} -gt 0 ]]; then
    echo "[\$(date -Is)] Rotating out \${#OLD_FILES[@]} old local staging archive(s)..."
    rm -f "\${OLD_FILES[@]}"
fi

podman image prune -f >/dev/null 2>&1 || true
echo "[\$(date -Is)] Stage 1 backup complete."
EOF

chmod +x "${APP_DIR}/scripts/${APP_NAME}-backup.sh"

cat > "${SYSTEMD_USER_DIR}/${APP_NAME}-backup.service" <<EOF
[Unit]
Description=${APP_NAME} Stage 1 Atomic Config Backup

[Service]
Type=oneshot
ExecStart=%h/containers/${APP_NAME}/scripts/${APP_NAME}-backup.sh
EOF

cat > "${SYSTEMD_USER_DIR}/${APP_NAME}-backup.timer" <<EOF
[Unit]
Description=Daily Stage 1 ${APP_NAME} Backup (02:00 AM)

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ==============================================================================
# 7. WRITE STAGE 2 CENTRALIZED NAS SYNC SCRIPT & SYSTEMD UNITS (02:30 AM)
# ==============================================================================
if [[ "$ENABLE_STAGE2" == true ]]; then
    info "Configuring Stage 2 centralized NAS sync service & timer (02:30 AM daily)..."

    cat > "${SHARED_SCRIPTS_DIR}/nas-backup-sync.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

STAGING_ROOT="\${HOME}/backups/staging"
NAS_BACKUP_ROOT="${NAS_BACKUP_ROOT}"
MOUNT_ROOT="${MOUNT_ROOT}"
KEEP_NAS=${NAS_KEEP_COUNT}

echo "[\$(date -Is)] Starting Stage 2 NAS sync -> \${NAS_BACKUP_ROOT}"

if [[ "\$MOUNT_ROOT" != "/" ]] && ! mountpoint -q "\$MOUNT_ROOT"; then
    echo "[\$(date -Is)] ERROR: Mount point '\${MOUNT_ROOT}' is NOT mounted! Aborting to protect local disk." >&2
    exit 1
fi

if [[ ! -f "\${NAS_BACKUP_ROOT}/.backup-target-verified" ]]; then
    echo "[\$(date -Is)] ERROR: Sentinel '\${NAS_BACKUP_ROOT}/.backup-target-verified' missing! Aborting." >&2
    exit 1
fi

# Free-space safety check: require at least 2 GB (2097152 KB) available on the destination
AVAIL_KB=\$(df -Pk "\${NAS_BACKUP_ROOT}" | awk 'NR==2 {print \$4}')
MIN_FREE_KB=2097152
if [[ -n "\$AVAIL_KB" ]] && (( AVAIL_KB < MIN_FREE_KB )); then
    AVAIL_MB=\$(( AVAIL_KB / 1024 ))
    echo "[\$(date -Is)] ERROR: Low disk space on '\${NAS_BACKUP_ROOT}' (\${AVAIL_MB} MB free; 2048 MB required). Aborting sync!" >&2
    exit 1
fi

rsync -av --ignore-existing --exclude='.*' "\${STAGING_ROOT}/" "\${NAS_BACKUP_ROOT}/"
if [[ -f "\${STAGING_ROOT}/HOW_TO_RESTORE.txt" ]]; then
    cp -f "\${STAGING_ROOT}/HOW_TO_RESTORE.txt" "\${NAS_BACKUP_ROOT}/HOW_TO_RESTORE.txt"
fi

# Keep only the newest KEEP_NAS archives inside each app subfolder on the NAS
if [[ "\$KEEP_NAS" -gt 0 ]]; then
    for APP_FOLDER in "\${NAS_BACKUP_ROOT}"/*/; do
        [[ -d "\$APP_FOLDER" ]] || continue
        mapfile -t OLD_NAS_FILES < <(ls -1t "\${APP_FOLDER}"*.tar.gz 2>/dev/null | tail -n +\$((KEEP_NAS + 1)))
        if [[ \${#OLD_NAS_FILES[@]} -gt 0 ]]; then
            echo "[\$(date -Is)] Pruning \${#OLD_NAS_FILES[@]} old archive(s) in \${APP_FOLDER}..."
            rm -f "\${OLD_NAS_FILES[@]}"
        fi
    done
fi

echo "[\$(date -Is)] Stage 2 NAS sync complete."
EOF

    chmod +x "${SHARED_SCRIPTS_DIR}/nas-backup-sync.sh"

    cat > "${SYSTEMD_USER_DIR}/nas-backup-sync.service" <<EOF
[Unit]
Description=Centralized Stage 2 Container Backup Sync to NAS

[Service]
Type=oneshot
ExecStart=%h/containers/shared-scripts/nas-backup-sync.sh
EOF

    cat > "${SYSTEMD_USER_DIR}/nas-backup-sync.timer" <<EOF
[Unit]
Description=Daily Stage 2 NAS Backup Sync (02:30 AM)

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
fi

# ==============================================================================
# 8. GENERATE SELF-DOCUMENTING HOW_TO_RESTORE.txt IN BOTH PARENT DIRECTORIES
# ==============================================================================
info "Writing HOW_TO_RESTORE.txt to local staging and Stage 2 backup roots..."

cat > "${STAGING_ROOT}/HOW_TO_RESTORE.txt" <<EOF
================================================================================
JELLYFIN DISASTER RECOVERY & RESTORE GUIDE (Instance: ${APP_NAME})
================================================================================
Generated for user: ${USER}
Instance name:      ${APP_NAME}
Host media path:    ${MEDIA_PATH}  (Mounted inside container as /media)
Local staging path: ${STAGING_APP}
Stage 2 path:       ${NAS_BACKUP_ROOT:-Disabled (Single-Stage Local Only)}

--------------------------------------------------------------------------------
SCENARIO A: RESTORE CONFIGURATION / DATABASE ON EXISTING SERVER
--------------------------------------------------------------------------------
1. Pick the backup archive you want to restore (e.g., ${APP_NAME}_YYYY-MM-DD_b0001.tar.gz)
   and verify it is readable:
     tar -tzf /path/to/${APP_NAME}_YYYY-MM-DD_b0001.tar.gz >/dev/null && echo "Archive OK"

2. Stop the container cleanly:
     systemctl --user stop ${APP_NAME}.service

3. Move the broken config folder aside (do not delete until restore is verified):
     mv ~/containers/${APP_NAME}/config ~/containers/${APP_NAME}/config.broken.\$(date +%F)

4. Extract the backup archive into ~/containers/${APP_NAME}/:
     tar -xzf /path/to/${APP_NAME}_YYYY-MM-DD_b0001.tar.gz -C ~/containers/${APP_NAME}/

5. Start the container again:
     systemctl --user start ${APP_NAME}.service

6. Once confirmed working, remove the old broken folder:
     rm -rf ~/containers/${APP_NAME}/config.broken.*

--------------------------------------------------------------------------------
SCENARIO B: FULL REBUILD ON A BRAND-NEW LINUX INSTALL
--------------------------------------------------------------------------------
1. Install dependencies:
     ${PKG_HINT}

2. Mount your media share to '${MEDIA_PATH}' (or any host path, as long as it maps
   to '/media' inside the container so watch history & favorites stay linked).

3. Recreate directories & enable linger:
     mkdir -p ~/.config/containers/systemd ~/.config/systemd/user ~/containers/${APP_NAME}/{config,cache,scripts}
     loginctl enable-linger \$USER

4. Extract your backup archive into ~/containers/${APP_NAME}/:
     tar -xzf /path/to/${APP_NAME}_YYYY-MM-DD_b0001.tar.gz -C ~/containers/${APP_NAME}/

5. Restore your Quadlet and backup timer units, then start the service:
     systemctl --user daemon-reload
     systemctl --user enable --now ${APP_NAME}-backup.timer
     systemctl --user start ${APP_NAME}.service

--------------------------------------------------------------------------------
MANUAL BACKUP & LOG COMMANDS
--------------------------------------------------------------------------------
  Run Stage 1 backup now:   systemctl --user start ${APP_NAME}-backup.service
  Run Stage 2 NAS sync now: systemctl --user start nas-backup-sync.service
  Check backup logs:        journalctl --user -u ${APP_NAME}-backup -u nas-backup-sync -n 50
  Check container logs:     journalctl --user -u ${APP_NAME} -f
================================================================================
EOF

if [[ "$ENABLE_STAGE2" == true ]]; then
    cp -f "${STAGING_ROOT}/HOW_TO_RESTORE.txt" "${NAS_BACKUP_ROOT}/HOW_TO_RESTORE.txt"
fi

# ==============================================================================
# 9. RELOAD SYSTEMD, ENABLE TIMERS & VERIFY CONTAINER STARTUP
# ==============================================================================
info "Reloading systemd user daemon and enabling backup timers..."
systemctl --user daemon-reload
systemctl --user enable --now "${APP_NAME}-backup.timer"
if [[ "$ENABLE_STAGE2" == true ]]; then
    systemctl --user enable --now nas-backup-sync.timer
fi

info "Pulling Jellyfin image and starting ${APP_NAME}.service (this may take a minute on first run)..."
systemctl --user start "${APP_NAME}.service"

info "Waiting for ${APP_NAME} web interface on http://localhost:${JELLYFIN_PORT} ..."
READY=false
for i in $(seq 1 45); do
    if curl -fsS "http://127.0.0.1:${JELLYFIN_PORT}/health" >/dev/null 2>&1 || \
       curl -fsS "http://127.0.0.1:${JELLYFIN_PORT}/web/index.html" >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 2
done

echo ""
if [[ "$READY" == true ]]; then
    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    LOCAL_URL="http://localhost:${JELLYFIN_PORT}"
    NET_URL=""
    [[ -n "$HOST_IP" ]] && NET_URL="http://${HOST_IP}:${JELLYFIN_PORT}"

    ok "${BOLD}${APP_NAME} is UP and responding!${NC}"
    echo ""
    echo -e "${BOLD}Open Jellyfin Setup Wizard (Ctrl+Click or copy URL):${NC}"
    echo "  Local:   ${LOCAL_URL}"
    if [[ -n "$NET_URL" ]]; then
        echo "  Network: ${NET_URL}"
        echo "           (If unreachable from other devices, allow port ${JELLYFIN_PORT}/tcp in your firewall)"
    fi
    echo ""
    echo -e "${BOLD}Recommended Post-Wizard Settings Inside Jellyfin:${NC}"
    echo "  1. Dashboard -> Libraries -> (3-dot menu) -> Manage library:"
    echo "     - Check 'Nfo' under Metadata savers"
    echo "     - Check 'Save artwork into media folders'"
    echo "  2. Test your backup pipeline right now:"
    echo "     systemctl --user start ${APP_NAME}-backup.service"
    if [[ "$ENABLE_STAGE2" == true ]]; then
        echo "     systemctl --user start nas-backup-sync.service"
    fi
else
    warn "${APP_NAME} container started, but port ${JELLYFIN_PORT} did not respond within 90 seconds."
    warn "It may still be initializing. Check status with: journalctl --user -u ${APP_NAME} -f"
fi

# ==============================================================================
# 10. OPTIONAL SELF-CLEANUP
# ==============================================================================
echo ""
if [[ "$KEEP_SCRIPT" == false ]]; then
    if ask_yes_no "Have you verified ${APP_NAME} is working and want to delete this bootstrap script now?" "N"; then
        SCRIPT_PATH="$(realpath "$0")"
        rm -f "$SCRIPT_PATH"
        ok "Removed ${SCRIPT_PATH}. Setup complete!"
    else
        info "Kept $(basename "$0") intact."
    fi
else
    info "Flag --keep passed: keeping $(basename "$0")."
fi
