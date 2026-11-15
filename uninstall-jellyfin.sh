#!/usr/bin/env bash
# ==============================================================================
# Jellyfin Rootless Podman Quadlet Uninstaller (v1.0)
# ==============================================================================
# Safely removes a rootless Jellyfin Quadlet instance and its Stage 1 backup
# timer while protecting host media libraries and optionally preserving backups.
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
    local default="${2:-N}"
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
# 1. ROOTLESS GUARD & INSTANCE SELECTION
# ==============================================================================
echo -e "\n${BOLD}=== Jellyfin Rootless Podman Quadlet Uninstaller ===${NC}\n"

if [[ "$EUID" -eq 0 ]]; then
    err "Do NOT run this script as root or with sudo."
    err "Run as the standard user that owns the rootless Quadlet."
    exit 1
fi

QUADLET_DIR="${HOME}/.config/containers/systemd"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SHARED_SCRIPTS_DIR="${HOME}/containers/shared-scripts"
STAGING_ROOT="${HOME}/backups/staging"

# Show detected Quadlet instances if any exist
if [[ -d "$QUADLET_DIR" ]]; then
    mapfile -t FOUND_INSTANCES < <(find "$QUADLET_DIR" -maxdepth 1 -name "*.container" -printf "%f\n" 2>/dev/null | sed 's/\.container$//' | sort)
    if [[ ${#FOUND_INSTANCES[@]} -gt 0 ]]; then
        info "Detected Quadlet instance(s): ${BOLD}${FOUND_INSTANCES[*]}${NC}"
    fi
fi

DEFAULT_APP_NAME="jellyfin"
while true; do
    read -rp "$(echo -e "${BOLD}Instance name to uninstall [${DEFAULT_APP_NAME}]: ${NC}")" APP_NAME
    APP_NAME="${APP_NAME:-$DEFAULT_APP_NAME}"
    if [[ ! "$APP_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        err "Invalid instance name '${APP_NAME}'."
        continue
    fi
    break
done

APP_DIR="${HOME}/containers/${APP_NAME}"
STAGING_APP="${STAGING_ROOT}/${APP_NAME}"
QUADLET_FILE="${QUADLET_DIR}/${APP_NAME}.container"
BACKUP_SVC="${SYSTEMD_USER_DIR}/${APP_NAME}-backup.service"
BACKUP_TMR="${SYSTEMD_USER_DIR}/${APP_NAME}-backup.timer"

# Auto-detect NAS backup root from shared sync script if present
NAS_BACKUP_ROOT=""
if [[ -f "${SHARED_SCRIPTS_DIR}/nas-backup-sync.sh" ]]; then
    NAS_BACKUP_ROOT=$(grep -E '^NAS_BACKUP_ROOT=' "${SHARED_SCRIPTS_DIR}/nas-backup-sync.sh" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
fi

# Verify something actually exists for this instance
if [[ ! -f "$QUADLET_FILE" && ! -d "$APP_DIR" && ! -f "$BACKUP_TMR" && ! -d "$STAGING_APP" ]]; then
    warn "No Quadlet, folders, or backup timers found for instance '${APP_NAME}'."
    exit 0
fi

# ==============================================================================
# 2. REVIEW REMOVAL SCOPE & BACKUP RETENTION CHOICES
# ==============================================================================
echo -e "\n${BOLD}--- Teardown Plan for '${APP_NAME}' ---${NC}"
echo "  * Stop & remove container service: ${APP_NAME}.service"
echo "  * Stop & remove Stage 1 timer:     ${APP_NAME}-backup.timer"
echo "  * Remove Quadlet & unit files:     ${QUADLET_FILE}"
echo "  * Remove app config/cache/scripts: ${APP_DIR}"
echo "  * Host media directories:          UNTOUCHED"
echo ""

if ! ask_yes_no "Proceed with uninstalling '${APP_NAME}'?" "N"; then
    info "Aborted safely. No changes were made."
    exit 0
fi

REMOVE_STAGING=false
if [[ -d "$STAGING_APP" || -f "${STAGING_ROOT}/.${APP_NAME}-backup.count" ]]; then
    if ask_yes_no "Also delete local staging backups (${STAGING_APP})?" "N"; then
        REMOVE_STAGING=true
    fi
fi

REMOVE_NAS=false
if [[ -n "$NAS_BACKUP_ROOT" && -d "${NAS_BACKUP_ROOT}/${APP_NAME}" ]]; then
    if ask_yes_no "Also delete NAS/ZFS backups (${NAS_BACKUP_ROOT}/${APP_NAME})?" "N"; then
        REMOVE_NAS=true
    fi
fi

# ==============================================================================
# 3. STOP SERVICES, DISABLE TIMERS & REMOVE UNIT FILES
# ==============================================================================
info "Stopping ${APP_NAME}.service and ${APP_NAME}-backup.timer..."
systemctl --user stop "${APP_NAME}.service" "${APP_NAME}-backup.timer" "${APP_NAME}-backup.service" 2>/dev/null || true
systemctl --user disable "${APP_NAME}-backup.timer" 2>/dev/null || true

info "Removing Quadlet and Stage 1 systemd unit files..."
rm -f "$QUADLET_FILE" "$BACKUP_SVC" "$BACKUP_TMR"

systemctl --user daemon-reload
systemctl --user reset-failed 2>/dev/null || true
ok "Removed systemd units and reloaded user daemon."

# ==============================================================================
# 4. REMOVE INSTANCE DIRECTORIES & OPTIONAL BACKUPS
# ==============================================================================
if [[ -d "$APP_DIR" ]]; then
    info "Removing ${APP_DIR}..."
    rm -rf "$APP_DIR"
    ok "Removed ${APP_DIR}."
fi

if [[ "$REMOVE_STAGING" == true ]]; then
    rm -rf "$STAGING_APP" "${STAGING_ROOT}/.${APP_NAME}-backup.count"
    ok "Removed local staging backups for '${APP_NAME}'."
elif [[ -d "$STAGING_APP" ]]; then
    info "Preserved local staging backups at ${STAGING_APP}."
fi

if [[ "$REMOVE_NAS" == true ]]; then
    rm -rf "${NAS_BACKUP_ROOT}/${APP_NAME}"
    ok "Removed NAS backups at ${NAS_BACKUP_ROOT}/${APP_NAME}."
elif [[ -n "$NAS_BACKUP_ROOT" && -d "${NAS_BACKUP_ROOT}/${APP_NAME}" ]]; then
    info "Preserved NAS backups at ${NAS_BACKUP_ROOT}/${APP_NAME}."
fi

# ==============================================================================
# 5. CHECK SHARED STAGE 2 NAS SYNC TIMER
# ==============================================================================
REMAINING_TIMERS=$(find "$SYSTEMD_USER_DIR" -maxdepth 1 -name "*-backup.timer" 2>/dev/null | wc -l)
if [[ "$REMAINING_TIMERS" -eq 0 ]] && [[ -f "${SYSTEMD_USER_DIR}/nas-backup-sync.timer" || -d "$SHARED_SCRIPTS_DIR" ]]; then
    echo ""
    info "No other container backup timers remain on this user account."
    if ask_yes_no "Remove shared Stage 2 NAS sync timer and ${SHARED_SCRIPTS_DIR}?" "N"; then
        systemctl --user stop nas-backup-sync.timer nas-backup-sync.service 2>/dev/null || true
        systemctl --user disable nas-backup-sync.timer 2>/dev/null || true
        rm -f "${SYSTEMD_USER_DIR}/nas-backup-sync.service" "${SYSTEMD_USER_DIR}/nas-backup-sync.timer"
        rm -rf "$SHARED_SCRIPTS_DIR"
        systemctl --user daemon-reload
        ok "Removed shared Stage 2 NAS sync timer and scripts."
    else
        info "Kept shared Stage 2 NAS sync timer intact."
    fi
elif [[ "$REMAINING_TIMERS" -gt 0 ]]; then
    info "Preserved shared Stage 2 NAS sync timer (${REMAINING_TIMERS} other backup timer(s) active)."
fi

# ==============================================================================
# 6. OPTIONAL IMAGE PRUNE
# ==============================================================================
echo ""
if command -v podman >/dev/null 2>&1; then
    if ask_yes_no "Prune unused container images (podman image prune -a) to reclaim disk space?" "N"; then
        podman image prune -af
        ok "Pruned unused Podman images."
    fi
fi

echo ""
ok "${BOLD}Uninstall complete for '${APP_NAME}'.${NC}"

