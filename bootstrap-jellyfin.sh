#!/usr/bin/env bash
# ==============================================================================
# Jellyfin Rootless Podman Quadlet & Two-Stage Backup Bootstrapper
# ==============================================================================
# Features:
#   - Cross-distro OS & Podman >= 4.4 gatekeeper (/etc/os-release)
#   - Rootless user check, /etc/subuid validation & smart loginctl linger prompt
#   - Smart NFS detection (auto-omits :Z on NFS, checks SELinux virt_use_nfs)
#   - Optional GPU transcoding (/dev/dri + GroupAdd=keep-groups) & CPU/IO priority
#   - Stage 1 (02:00): Atomic cold-stop backup -> YYYY-MM-DD_b0001.tar.gz (keep 2)
#   - Stage 2 (02:30): Centralized ZFS NFS sync (--ignore-existing, mount guard)
#   - Generates HOW_TO_RESTORE.txt in both local staging and NAS backup roots
#   - Verifies live HTTP response on port 8096 and optionally self-deletes
#
# Usage:
#   chmod +x bootstrap-jellyfin.sh
#   ./bootstrap-jellyfin.sh           # Interactive setup (offers self-cleanup)
#   ./bootstrap-jellyfin.sh --keep    # Keep bootstrap script after completion
# ==============================================================================

set -euo pipefail

KEEP_SCRIPT=false
for arg in "$@"; do
    case "$arg" in
        --keep|--no-self-delete) KEEP_SCRIPT=true ;;
        -h|--help)
            echo "Usage: $0 [--keep]"
            echo "  --keep    Do not offer to delete this script after verification."
            exit 0
            ;;
    esac
done

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

# OS Detection via /etc/os-release
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

# Check /etc/subuid and /etc/subgid
if ! grep -q "^${USER}:" /etc/subuid 2>/dev/null || ! grep -q "^${USER}:" /etc/subgid 2>/dev/null; then
    err "User '${USER}' lacks subordinate UID/GID ranges in /etc/subuid or /etc/subgid."
    info "Fix this as root with:"
    echo "  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${USER}"
    exit 1
fi
ok "Rootless subuid/subgid mappings verified for '${USER}'."
# === END OF PART 1 ===
# Smart User Linger Check
LINGER_STATE=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo "no")
if [[ "$LINGER_STATE" == "yes" ]]; then
    ok "User lingering is already enabled for '${USER}'."
else
    echo ""
    warn "User lingering is currently DISABLED for '${USER}'."
    echo "  Why this matters: Without lingering, systemd stops your rootless Podman"
    echo "  containers and backup timers whenever you log out of SSH or your desktop,"
    echo "  and will not auto-start Jellyfin on reboot until you manually log in."
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
# 3. INTERACTIVE PATHS & HARDWARE CONFIGURATION
# ==============================================================================
echo -e "\n${BOLD}--- Storage, Backup & Hardware Prompts ---${NC}"

# Prompt 1: Media Path
DEFAULT_MEDIA="/mnt/media/data"
while true; do
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

    # Warn if path itself is a bare mountpoint rather than a subfolder
    if mountpoint -q "$MEDIA_PATH"; then
        warn "'${MEDIA_PATH}' is a top-level mount point."
        warn "Using a subfolder (e.g., ${MEDIA_PATH}/data) prevents Jellyfin from wiping"
        warn "your library metadata if an NFS/external drive ever disconnects."
        if ! ask_yes_no "Use '${MEDIA_PATH}' anyway?" "N"; then
            continue
        fi
    fi
    break
done

# Detect NFS & SELinux for Media Volume Label
MEDIA_FSTYPE=$(stat -f -c %T "$MEDIA_PATH" 2>/dev/null || echo "unknown")
MEDIA_VOL_OPTS=""
if [[ "$MEDIA_FSTYPE" == "nfs"* ]]; then
    ok "Detected NFS filesystem (${MEDIA_FSTYPE}) for media -> omitting :Z label."
    if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
        if command -v getsebool >/dev/null 2>&1 && ! getsebool virt_use_nfs 2>/dev/null | grep -q "on$"; then
            warn "SELinux is Enforcing and 'virt_use_nfs' is OFF!"
            warn "Run: sudo setsebool -P virt_use_nfs 1"
        fi
    fi
else
    MEDIA_VOL_OPTS=":Z"
    ok "Detected local filesystem (${MEDIA_FSTYPE}) for media -> using :Z label."
fi

# Prompt 2: NAS / ZFS Backup Destination
DEFAULT_NAS_BACKUP="/mnt/nas/container-backups"
while true; do
    echo ""
    read -rp "$(echo -e "${BOLD}Host path to NAS/ZFS backup parent directory [${DEFAULT_NAS_BACKUP}]: ${NC}")" NAS_BACKUP_ROOT
    NAS_BACKUP_ROOT="${NAS_BACKUP_ROOT:-$DEFAULT_NAS_BACKUP}"
    NAS_BACKUP_ROOT="${NAS_BACKUP_ROOT%/}"

    # Walk up to find nearest existing ancestor and verify it's mounted
    CHECK_DIR="$NAS_BACKUP_ROOT"
    while [[ ! -e "$CHECK_DIR" && "$CHECK_DIR" != "/" ]]; do
        CHECK_DIR="$(dirname "$CHECK_DIR")"
    done

    MOUNT_ROOT=$(findmnt -T "$CHECK_DIR" -no TARGET 2>/dev/null || echo "/")
    if [[ "$MOUNT_ROOT" == "/" ]]; then
        warn "'${NAS_BACKUP_ROOT}' resolves to your local root filesystem (/)."
        warn "If this is supposed to be an NFS ZFS mount, ensure it is mounted first!"
        if ! ask_yes_no "Proceed with '${NAS_BACKUP_ROOT}' anyway?" "N"; then
            continue
        fi
    else
        ok "Verified '${NAS_BACKUP_ROOT}' resides on active mount point '${MOUNT_ROOT}'."
    fi

    if ! mkdir -p "${NAS_BACKUP_ROOT}/jellyfin" 2>/dev/null; then
        err "Permission denied creating '${NAS_BACKUP_ROOT}/jellyfin'."
        info "On your host, run: sudo mkdir -p '${NAS_BACKUP_ROOT}' && sudo chown -R ${USER}:${USER} '${NAS_BACKUP_ROOT}'"
        if ask_yes_no "Retry after fixing permissions?" "Y"; then
            continue
        else
            exit 1
        fi
    fi

    touch "${NAS_BACKUP_ROOT}/.backup-target-verified"
    ok "NAS backup target verified and writable."
    break
done

# Prompt 3: Port Selection
read -rp "$(echo -e "${BOLD}Host HTTP port for Jellyfin web UI: ${NC}")" JELLYFIN_PORT
JELLYFIN_PORT="${JELLYFIN_PORT:-8096}"

# Prompt 4: GPU Hardware Transcoding
ENABLE_GPU=false
if [[ -d /dev/dri ]]; then
    echo ""
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

# Prompt 6: NAS Retention Days
read -rp "$(echo -e "${BOLD}Days to retain backups on NAS/ZFS warehouse: ${NC}")" NAS_RETENTION_DAYS
NAS_RETENTION_DAYS="${NAS_RETENTION_DAYS:-30}"
# === END OF PART 2A ===
# ==============================================================================
# 4. CREATE DIRECTORY STRUCTURE
# ==============================================================================
info "Creating rootless directory hierarchy in ${HOME}..."

QUADLET_DIR="${HOME}/.config/containers/systemd"
APP_DIR="${HOME}/containers/jellyfin"
SHARED_SCRIPTS_DIR="${HOME}/containers/shared-scripts"
STAGING_ROOT="${HOME}/backups/staging"
STAGING_JF="${STAGING_ROOT}/jellyfin"

mkdir -p \
    "$QUADLET_DIR" \
    "${APP_DIR}/config" \
    "${APP_DIR}/cache" \
    "${APP_DIR}/scripts" \
    "$SHARED_SCRIPTS_DIR" \
    "$STAGING_JF"

# ==============================================================================
# 5. WRITE JELLYFIN QUADLET FILE
# ==============================================================================
info "Writing Quadlet unit: ${QUADLET_DIR}/jellyfin.container"

GPU_BLOCK=""
if [[ "$ENABLE_GPU" == true ]]; then
    GPU_BLOCK=$'# Hardware Transcoding (/dev/dri)\nAddDevice=/dev/dri:/dev/dri\nGroupAdd=keep-groups'
fi

PRIORITY_BLOCK=""
if [[ "$LOW_PRIORITY" == true ]]; then
    PRIORITY_BLOCK=$'# Keep host desktop/services responsive during heavy scans/transcodes\nNice=10\nCPUWeight=50\nIOSchedulingPriority=6'
fi

cat > "${QUADLET_DIR}/jellyfin.container" <<EOF
[Unit]
Description=Jellyfin Media Server (Rootless Podman Quadlet)
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/jellyfin/jellyfin:latest
ContainerName=jellyfin
AutoUpdate=registry

# Networking
PublishPort=${JELLYFIN_PORT}:8096

# Persistent & Disposable Storage
Volume=%h/containers/jellyfin/config:/config:Z
Volume=%h/containers/jellyfin/cache:/cache:Z
Volume=${MEDIA_PATH}:/media${MEDIA_VOL_OPTS}

${GPU_BLOCK}

[Service]
Restart=always
TimeoutStartSec=300
${PRIORITY_BLOCK}

[Install]
WantedBy=default.target
EOF

# Keep a copy of the Quadlet inside ~/containers/jellyfin for single-folder portability
cp "${QUADLET_DIR}/jellyfin.container" "${APP_DIR}/jellyfin.container.backup"

# ==============================================================================
# 6. WRITE STAGE 1 BACKUP SCRIPT & SYSTEMD UNITS (LOCAL STAGING, KEEP 2)
# ==============================================================================
info "Configuring Stage 1 atomic backup script & timer (02:00 AM daily)..."

cat > "${APP_DIR}/scripts/jellyfin-backup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="jellyfin"
CONFIG_PARENT="${HOME}/containers/${APP_NAME}"
STAGING_ROOT="${HOME}/backups/staging"
STAGING_DIR="${STAGING_ROOT}/${APP_NAME}"
COUNT_FILE="${STAGING_ROOT}/.${APP_NAME}-backup.count"
KEEP_LOCAL=2

mkdir -p "$STAGING_DIR"

# Increment sequential run counter (0001, 0002, ...)
LAST_NUM=0
if [[ -f "$COUNT_FILE" ]]; then
    LAST_NUM=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
fi
NEXT_NUM=$((10#$LAST_NUM + 1))
printf "%04d" "$NEXT_NUM" > "$COUNT_FILE"
SEQ_TAG=$(printf "b%04d" "$NEXT_NUM")
DATE_TAG=$(date +%F)

ARCHIVE_NAME="${APP_NAME}_${DATE_TAG}_${SEQ_TAG}.tar.gz"
TMP_ARCHIVE="/tmp/${ARCHIVE_NAME}"
FINAL_ARCHIVE="${STAGING_DIR}/${ARCHIVE_NAME}"

echo "[$(date -Is)] Starting cold-stop backup: ${ARCHIVE_NAME}"

# Ensure Jellyfin always restarts even if tar fails
restart_service() {
    echo "[$(date -Is)] Starting ${APP_NAME}.service..."
    systemctl --user start "${APP_NAME}.service"
}
trap restart_service EXIT

systemctl --user stop "${APP_NAME}.service"
tar -czf "$TMP_ARCHIVE" -C "$CONFIG_PARENT" config
mv "$TMP_ARCHIVE" "$FINAL_ARCHIVE"

# Restart immediately via trap, then clear trap
restart_service
trap - EXIT

echo "[$(date -Is)] Backup saved to ${FINAL_ARCHIVE} ($(du -h "$FINAL_ARCHIVE" | cut -f1))"

# Rotate local staging: keep only the newest $KEEP_LOCAL archives
mapfile -t OLD_FILES < <(ls -1t "${STAGING_DIR}/${APP_NAME}_"*.tar.gz 2>/dev/null | tail -n +$((KEEP_LOCAL + 1)))
if [[ ${#OLD_FILES[@]} -gt 0 ]]; then
    echo "[$(date -Is)] Rotating out ${#OLD_FILES[@]} old local staging archive(s)..."
    rm -f "${OLD_FILES[@]}"
fi

# Prune superseded Podman images to prevent disk bloat
podman image prune -f >/dev/null 2>&1 || true
echo "[$(date -Is)] Stage 1 backup complete."
EOF

chmod +x "${APP_DIR}/scripts/jellyfin-backup.sh"

cat > "${QUADLET_DIR}/jellyfin-backup.service" <<EOF
[Unit]
Description=Jellyfin Stage 1 Atomic Config Backup

[Service]
Type=oneshot
ExecStart=%h/containers/jellyfin/scripts/jellyfin-backup.sh
EOF

cat > "${QUADLET_DIR}/jellyfin-backup.timer" <<EOF
[Unit]
Description=Daily Stage 1 Jellyfin Backup (02:00 AM)

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
# === END OF PART 2B-1 ===
# ==============================================================================
# 7. WRITE STAGE 2 CENTRALIZED NAS SYNC SCRIPT & SYSTEMD UNITS (02:30 AM)
# ==============================================================================
info "Configuring Stage 2 centralized NAS sync service & timer (02:30 AM daily)..."

cat > "${SHARED_SCRIPTS_DIR}/nas-backup-sync.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

STAGING_ROOT="\${HOME}/backups/staging"
NAS_BACKUP_ROOT="${NAS_BACKUP_ROOT}"
MOUNT_ROOT="${MOUNT_ROOT}"
RETENTION_DAYS=${NAS_RETENTION_DAYS}

echo "[\$(date -Is)] Starting Stage 2 NAS sync -> \${NAS_BACKUP_ROOT}"

# Guard 1: Verify mount point if not on root filesystem
if [[ "\$MOUNT_ROOT" != "/" ]] && ! mountpoint -q "\$MOUNT_ROOT"; then
    echo "[\$(date -Is)] ERROR: Mount point '\${MOUNT_ROOT}' is NOT mounted! Aborting to protect local disk." >&2
    exit 1
fi

# Guard 2: Verify sentinel file
if [[ ! -f "\${NAS_BACKUP_ROOT}/.backup-target-verified" ]]; then
    echo "[\$(date -Is)] ERROR: Sentinel '\${NAS_BACKUP_ROOT}/.backup-target-verified' missing! Aborting." >&2
    exit 1
fi

# Push new archives without re-copying existing ones; always update HOW_TO_RESTORE.txt
rsync -av --ignore-existing --exclude='.*' "\${STAGING_ROOT}/" "\${NAS_BACKUP_ROOT}/"
if [[ -f "\${STAGING_ROOT}/HOW_TO_RESTORE.txt" ]]; then
    cp -f "\${STAGING_ROOT}/HOW_TO_RESTORE.txt" "\${NAS_BACKUP_ROOT}/HOW_TO_RESTORE.txt"
fi

# Prune archives older than RETENTION_DAYS on the NAS warehouse
if [[ "\$RETENTION_DAYS" -gt 0 ]]; then
    find "\${NAS_BACKUP_ROOT}" -type f -name "*.tar.gz" -mtime +"${NAS_RETENTION_DAYS}" -delete
fi

echo "[\$(date -Is)] Stage 2 NAS sync complete."
EOF

chmod +x "${SHARED_SCRIPTS_DIR}/nas-backup-sync.sh"

cat > "${QUADLET_DIR}/nas-backup-sync.service" <<EOF
[Unit]
Description=Centralized Stage 2 Container Backup Sync to NAS

[Service]
Type=oneshot
ExecStart=%h/containers/shared-scripts/nas-backup-sync.sh
EOF

cat > "${QUADLET_DIR}/nas-backup-sync.timer" <<EOF
[Unit]
Description=Daily Stage 2 NAS Backup Sync (02:30 AM)

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ==============================================================================
# 8. GENERATE SELF-DOCUMENTING HOW_TO_RESTORE.txt IN BOTH PARENT DIRECTORIES
# ==============================================================================
info "Writing HOW_TO_RESTORE.txt to local staging and NAS backup roots..."

cat > "${STAGING_ROOT}/HOW_TO_RESTORE.txt" <<EOF
================================================================================
JELLYFIN DISASTER RECOVERY & RESTORE GUIDE
================================================================================
Generated for user: ${USER}
Host media path:    ${MEDIA_PATH}  (Mounted inside container as /media)
Local staging path: ${STAGING_ROOT}/jellyfin
NAS backup path:    ${NAS_BACKUP_ROOT}/jellyfin

--------------------------------------------------------------------------------
SCENARIO A: RESTORE CONFIGURATION / DATABASE ON EXISTING SERVER
--------------------------------------------------------------------------------
1. Pick the backup archive you want to restore (e.g., jellyfin_YYYY-MM-DD_b0001.tar.gz)
   and verify it is readable:
     tar -tzf /path/to/jellyfin_YYYY-MM-DD_b0001.tar.gz >/dev/null && echo "Archive OK"

2. Stop the Jellyfin container cleanly:
     systemctl --user stop jellyfin.service

3. Move the broken config folder aside (do not delete until restore is verified):
     mv ~/containers/jellyfin/config ~/containers/jellyfin/config.broken.\$(date +%F)

4. Extract the backup archive into ~/containers/jellyfin/:
     tar -xzf /path/to/jellyfin_YYYY-MM-DD_b0001.tar.gz -C ~/containers/jellyfin/

5. Start Jellyfin again:
     systemctl --user start jellyfin.service

6. Once confirmed working, remove the old broken folder:
     rm -rf ~/containers/jellyfin/config.broken.*

--------------------------------------------------------------------------------
SCENARIO B: FULL REBUILD ON A BRAND-NEW LINUX INSTALL
--------------------------------------------------------------------------------
1. Install dependencies:
     ${PKG_HINT}

2. Mount your media share to '${MEDIA_PATH}' (or any host path, as long as it maps
   to '/media' inside the container so watch history & favorites stay linked).

3. Recreate directories & enable linger:
     mkdir -p ~/.config/containers/systemd ~/containers/jellyfin/{config,cache,scripts}
     loginctl enable-linger \$USER

4. Extract your backup archive into ~/containers/jellyfin/:
     tar -xzf /path/to/jellyfin_YYYY-MM-DD_b0001.tar.gz -C ~/containers/jellyfin/

5. Restore your Quadlet file to ~/.config/containers/systemd/jellyfin.container
   and start the service:
     systemctl --user daemon-reload
     systemctl --user start jellyfin.service

--------------------------------------------------------------------------------
MANUAL BACKUP & LOG COMMANDS
--------------------------------------------------------------------------------
  Run Stage 1 backup now:   systemctl --user start jellyfin-backup.service
  Run Stage 2 NAS sync now: systemctl --user start nas-backup-sync.service
  Check backup logs:        journalctl --user -u jellyfin-backup -u nas-backup-sync -n 50
  Check Jellyfin logs:      journalctl --user -u jellyfin -f
================================================================================
EOF

cp -f "${STAGING_ROOT}/HOW_TO_RESTORE.txt" "${NAS_BACKUP_ROOT}/HOW_TO_RESTORE.txt"

# ==============================================================================
# 9. RELOAD SYSTEMD, ENABLE TIMERS & VERIFY JELLYFIN STARTUP
# ==============================================================================
info "Reloading systemd user daemon and enabling backup timers..."
systemctl --user daemon-reload
systemctl --user enable --now jellyfin-backup.timer
systemctl --user enable --now nas-backup-sync.timer

info "Pulling Jellyfin image and starting jellyfin.service (this may take a minute on first run)..."
systemctl --user start jellyfin.service

info "Waiting for Jellyfin web interface on http://localhost:${JELLYFIN_PORT} ..."
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
    ok "${BOLD}Jellyfin is UP and responding!${NC}"
    echo -e "  Local URL:   ${BOLD}http://localhost:${JELLYFIN_PORT}${NC}"
    [[ -n "$HOST_IP" ]] && echo -e "  Network URL: ${BOLD}http://${HOST_IP}:${JELLYFIN_PORT}${NC}"
    echo ""
    echo -e "${BOLD}Recommended Post-Wizard Settings Inside Jellyfin:${NC}"
    echo "  1. Dashboard -> Libraries -> (3-dot menu) -> Manage library:"
    echo "     - Check 'Nfo' under Metadata savers"
    echo "     - Check 'Save artwork into media folders'"
    echo "  2. Test your backup pipeline right now with:"
    echo "     systemctl --user start jellyfin-backup.service && systemctl --user start nas-backup-sync.service"
else
    warn "Jellyfin container started, but port ${JELLYFIN_PORT} did not respond within 90 seconds."
    warn "It may still be initializing. Check status with: journalctl --user -u jellyfin -f"
fi

# ==============================================================================
# 10. OPTIONAL SELF-CLEANUP
# ==============================================================================
echo ""
if [[ "$KEEP_SCRIPT" == false ]]; then
    if ask_yes_no "Have you verified Jellyfin is working and want to delete this bootstrap script now?" "N"; then
        SCRIPT_PATH="$(realpath "$0")"
        rm -f "$SCRIPT_PATH"
        ok "Removed ${SCRIPT_PATH}. Setup complete!"
    else
        info "Kept $(basename "$0") intact."
    fi
else
    info "Flag --keep passed: keeping $(basename "$0")."
fi
# === END OF SCRIPT ===

