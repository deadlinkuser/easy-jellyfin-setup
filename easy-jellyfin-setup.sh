#!/usr/bin/env bash
# ==============================================================================
# easy-jellyfin-setup (v2.0.0-beta)
# Beginner-Friendly Rootless Podman Quadlet & Native Linux Jellyfin Installer
# ==============================================================================
# Repository: https://github.com
#
# [NOTE] Why this script is written this way:
#   This script is designed both to be easy for newcomers to run AND easy for
#   new contributors to read. Look for "# [NOTE]" blocks throughout the file
#   to see why each check, permission, or Podman flag is used.
# ==============================================================================

# [NOTE] Bash "Strict Mode":
#   -e : Exit immediately if any command fails (prevents cascading errors).
#   -u : Treat unset variables as errors (catches typos in variable names).
#   -o pipefail : Fail a pipeline if ANY command in it fails, not just the last.
set -euo pipefail

PROJECT_NAME="easy-jellyfin-setup"
PROJECT_VERSION="2.0.0-beta"
FEEDBACK_URL="https://github.com/issues"

# ==============================================================================
# 0. CLI FLAGS & ARGUMENT PARSING
# ==============================================================================
# [NOTE] Supporting simple flags (--backup, --uninstall, --keep) lets users
#   manage their server lifecycle with one script instead of memorizing dozens
#   of systemctl, podman, or tar commands.
KEEP_SCRIPT=false
ACTION="install"
TARGET_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep|--no-self-delete)
            KEEP_SCRIPT=true
            shift
            ;;
        --backup)
            ACTION="backup"
            if [[ -n "${2:-}" && ! "${2:-}" =~ ^- ]]; then
                TARGET_NAME="$2"
                shift
            fi
            shift
            ;;
        --uninstall)
            ACTION="uninstall"
            if [[ -n "${2:-}" && ! "${2:-}" =~ ^- ]]; then
                TARGET_NAME="$2"
                shift
            fi
            shift
            ;;
        -h|--help)
            cat <<EOF
${PROJECT_NAME} (${PROJECT_VERSION})

Usage:
  ./$(basename "$0")                 Run the guided Jellyfin installer
  ./$(basename "$0") --keep          Keep this script after installation completes
  ./$(basename "$0") --backup [name] Create a safe local backup archive on demand
  ./$(basename "$0") --uninstall [name] Cleanly remove a Jellyfin install
  ./$(basename "$0") --help          Show this help message
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1 (run with --help for usage)" >&2
            exit 1
            ;;
    esac
done

# ==============================================================================
# 1. TERMINAL COLORS & HELPER FUNCTIONS
# ==============================================================================
# [NOTE] ANSI color codes make status messages scannable so newcomers can
#   immediately spot [OK], [WARN], and [ERR] lines in a busy terminal.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC}  $*" >&2; }

# [NOTE] ask_yes_no standardizes Y/n prompts across the script.
#   Pressing Enter without typing anything accepts the capitalized default.
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
# 2. DETECT HOST OPERATING SYSTEM
# ==============================================================================
# [NOTE] /etc/os-release is the Linux standard file that identifies the distro
#   (Debian, Ubuntu, Fedora, RHEL, Arch, etc.) without brittle file checks.
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

# [NOTE] Provide helpful package-manager hints tailored to the user's distro.
PKG_HINT="Install podman (>= 4.4), tar, and curl using your system package manager."
case "$OS_ID" in
    debian|ubuntu|pop|linuxmint)
        PKG_HINT="sudo apt update && sudo apt install -y podman tar curl"
        ;;
    fedora|rhel|rocky|almalinux|centos)
        PKG_HINT="sudo dnf install -y podman tar curl"
        ;;
    opensuse-tumbleweed|opensuse-leap|sles)
        PKG_HINT="sudo zypper install -y podman tar curl"
        ;;
    arch|endeavouros|manjaro)
        PKG_HINT="sudo pacman -S --needed podman tar curl"
        ;;
    *)
        if [[ "$OS_LIKE" == *"debian"* ]]; then
            PKG_HINT="sudo apt update && sudo apt install -y podman tar curl"
        elif [[ "$OS_LIKE" == *"rhel"* || "$OS_LIKE" == *"fedora"* ]]; then
            PKG_HINT="sudo dnf install -y podman tar curl"
        fi
        ;;
esac

# ==============================================================================
# 3. ON-DEMAND BACKUP FUNCTION (--backup)
# ==============================================================================
# [NOTE] Why we stop Jellyfin briefly during backups:
#   Jellyfin stores watch history and library metadata in SQLite databases.
#   Copying a live SQLite database while Jellyfin is writing to it can produce
#   a corrupted backup. Stopping the service for a few seconds guarantees a
#   100% consistent "cold" backup archive that the user can safely copy to a
#   NAS, external drive, or cloud folder whenever they like.
run_backup() {
    echo -e "\n${BOLD}=== ${PROJECT_NAME}: On-Demand Local Backup ===${NC}\n"

    if [[ "$EUID" -eq 0 ]]; then
        err "Do NOT run --backup as root/sudo. Run as your standard user."
        exit 1
    fi

    local app_name="${TARGET_NAME}"
    if [[ -z "$app_name" ]]; then
        read -rp "$(echo -e "${BOLD}Instance name to back up [jellyfin]: ${NC}")" app_name
        app_name="${app_name:-jellyfin}"
    fi

    local quadlet_file="${HOME}/.config/containers/systemd/${app_name}.container"
    local container_config="${HOME}/containers/${app_name}/config"
    local backup_dir="${HOME}/backups/${app_name}"
    local date_tag
    date_tag=$(date +%F_%H%M)
    local archive_path="${backup_dir}/${app_name}_${date_tag}.tar.gz"

    # Case A: Rootless Podman Container Instance
    if [[ -f "$quadlet_file" && -d "$container_config" ]]; then
        mkdir -p "$backup_dir"

        # [NOTE] Record whether the container was running before we started so we
        #   never accidentally wake up a container the user intentionally stopped.
        local was_running=false
        if systemctl --user is-active --quiet "${app_name}.service"; then
            was_running=true
            info "Pausing ${app_name}.service for a safe cold database backup..."
            systemctl --user stop "${app_name}.service"
        else
            info "${app_name}.service is already stopped; backing up cold config..."
        fi

        # [NOTE] Ensure the service restarts even if tar encounters an error.
        trap '[[ "$was_running" == true ]] && systemctl --user start "${app_name}.service"' EXIT

        # [NOTE] Exclude disposable cache and transcode temp files so the backup
        #   archive stays small, fast, and focused on your database & settings.
        tar --exclude='config/cache' --exclude='config/transcodes' \
            -czf "$archive_path" -C "${HOME}/containers/${app_name}" config

        if [[ "$was_running" == true ]]; then
            info "Starting ${app_name}.service back up..."
            systemctl --user start "${app_name}.service"
        fi
        trap - EXIT

        ok "Backup created: ${BOLD}${archive_path}${NC} ($(du -h "$archive_path" | cut -f1))"
        echo "  Tip: You can copy this .tar.gz file to your NAS or USB drive anytime."
        exit 0
    fi

    # Case B: Native System Package Install (/var/lib/jellyfin)
        # Case B: Native System Package Install (/var/lib/jellyfin)
    if [[ "$app_name" == "jellyfin" && -d "/var/lib/jellyfin" ]] && systemctl list-unit-files jellyfin.service >/dev/null 2>&1; then

        mkdir -p "$backup_dir"
        local native_was_running=false
        if systemctl is-active --quiet jellyfin.service; then
            native_was_running=true
            info "Pausing system jellyfin.service (requires sudo)..."
            sudo systemctl stop jellyfin.service
        fi

        trap '[[ "$native_was_running" == true ]] && sudo systemctl start jellyfin.service' EXIT

        sudo tar --exclude='*/cache' --exclude='*/transcodes' \
            -czf "$archive_path" -C /var/lib jellyfin
        sudo chown "${USER}:${USER}" "$archive_path"

        if [[ "$native_was_running" == true ]]; then
            sudo systemctl start jellyfin.service
        fi
        trap - EXIT

        ok "Native backup created: ${BOLD}${archive_path}${NC} ($(du -h "$archive_path" | cut -f1))"
        echo "  Tip: You can copy this .tar.gz file to your NAS or USB drive anytime."
        exit 0
    fi

    err "No Podman Quadlet ('${app_name}') or native Jellyfin install was found."
    exit 1
}

# ==============================================================================
# 4. UNIFIED UNINSTALLER FUNCTION (--uninstall)
# ==============================================================================
# [NOTE] Cleanly removes either a Rootless Podman Quadlet OR a Native system
#   package install, while keeping media folders untouched and asking before
#   deleting configuration or backup data.
run_uninstall() {
    echo -e "\n${BOLD}=== ${PROJECT_NAME}: Clean Uninstaller ===${NC}\n"

    if [[ "$EUID" -eq 0 ]]; then
        err "Do NOT run --uninstall as root/sudo. Run as your standard user."
        exit 1
    fi

    local app_name="${TARGET_NAME}"
    if [[ -z "$app_name" ]]; then
        read -rp "$(echo -e "${BOLD}Instance name to uninstall [jellyfin]: ${NC}")" app_name
        app_name="${app_name:-jellyfin}"
    fi

    local quadlet_file="${HOME}/.config/containers/systemd/${app_name}.container"
    local app_dir="${HOME}/containers/${app_name}"
    local backup_dir="${HOME}/backups/${app_name}"
    local found_something=false

    # --- Check 1: Rootless Podman Quadlet ---
    if [[ -f "$quadlet_file" || -d "$app_dir" ]]; then
        found_something=true
        info "Found Rootless Podman Quadlet setup for '${app_name}'."
        if ask_yes_no "Stop and remove '${app_name}' container and Quadlet unit?" "N"; then
            systemctl --user stop "${app_name}.service" 2>/dev/null || true
            rm -f "$quadlet_file"
            systemctl --user daemon-reload
            systemctl --user reset-failed 2>/dev/null || true
            ok "Removed Quadlet unit and stopped ${app_name}.service."

            if [[ -d "$app_dir" ]]; then
                if ask_yes_no "Delete container config & cache folder (${app_dir})? (No = keep data)" "N"; then
                    rm -rf "$app_dir"
                    ok "Deleted ${app_dir}."
                else
                    info "Preserved ${app_dir}."
                fi
            fi

            if [[ -d "$backup_dir" ]]; then
                if ask_yes_no "Delete local backups (${backup_dir})?" "N"; then
                    rm -rf "$backup_dir"
                    ok "Deleted ${backup_dir}."
                else
                    info "Preserved ${backup_dir}."
                fi
            fi

            if ask_yes_no "Remove the downloaded jellyfin/jellyfin container image to free disk space?" "N"; then
                podman rmi docker.io/jellyfin/jellyfin:latest 2>/dev/null || true
                podman image prune -f >/dev/null 2>&1 || true
                ok "Removed container image."
            fi
        fi
    fi

    # --- Check 2: Native System Package Install ---
    if [[ "$app_name" == "jellyfin" ]] && systemctl list-unit-files jellyfin.service >/dev/null 2>&1; then
        found_something=true
        info "Found Native system package install of Jellyfin."
        if ask_yes_no "Stop and uninstall native Jellyfin system packages (requires sudo)?" "N"; then
            sudo systemctl disable --now jellyfin.service 2>/dev/null || true
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get remove -y jellyfin jellyfin-server jellyfin-web jellyfin-ffmpeg* || true
                sudo apt-get autoremove -y || true
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf remove -y jellyfin jellyfin-server jellyfin-web || true
            fi
            ok "Native Jellyfin packages removed."

            if [[ -d /var/lib/jellyfin ]]; then
                if ask_yes_no "Delete /var/lib/jellyfin and /etc/jellyfin? (No = keep data)" "N"; then
                    sudo rm -rf /var/lib/jellyfin /etc/jellyfin /var/log/jellyfin /var/cache/jellyfin
                    ok "Deleted native Jellyfin data directories."
                else
                    info "Preserved /var/lib/jellyfin."
                fi
            fi
        fi
    fi

    if [[ "$found_something" == false ]]; then
        warn "No Podman Quadlet or native Jellyfin installation found for '${app_name}'."
    else
        ok "Uninstall complete! (Your media files were never touched.)"
    fi
    exit 0
}

# Route early if --backup or --uninstall was requested
[[ "$ACTION" == "backup" ]] && run_backup
[[ "$ACTION" == "uninstall" ]] && run_uninstall

# ==============================================================================
# 5. INTERACTIVE INSTALLER: SAFETY CHECKS & MODE SELECTION
# ==============================================================================
echo -e "\n${BOLD}============================================================${NC}"
echo -e "${BOLD}  Welcome to ${PROJECT_NAME} (${PROJECT_VERSION})${NC}"
echo -e "${BOLD}============================================================${NC}"
info "Detected OS: ${BOLD}${OS_PRETTY}${NC}\n"

# [NOTE] Always run as a standard user! Even if the user chooses Native mode,
#   running as a normal user first lets us protect $HOME paths and use sudo
#   only for the specific package-install commands that require root.
if [[ "$EUID" -eq 0 ]]; then
    err "Do NOT run this script as root or with sudo."
    err "Log in as your regular user and run: ./$(basename "$0")"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    err "systemd (systemctl) was not found. This installer requires a systemd Linux distro."
    exit 1
fi

# [NOTE] Explain WHY containers are recommended so newcomers understand the
#   trade-offs rather than blindly picking an option.
echo -e "${BOLD}Choose how you would like to install Jellyfin:${NC}"
echo ""
echo -e "  ${GREEN}${BOLD}1) Rootless Podman Container (Recommended)${NC}"
echo "     * Clean & Isolated: Keeps Jellyfin and its dependencies in a self-contained"
echo "       box without cluttering your host operating system."
echo "     * Safe & Rootless: Runs under your normal user account—no root daemon needed."
echo "     * Easy Backups & Upgrades: All settings live in ~/containers/jellyfin/config,"
echo "       making updates or moving to a new PC effortless."
echo ""
echo -e "  ${CYAN}${BOLD}2) Native Linux Package Install (Bare-Metal)${NC}"
echo "     * Installs Jellyfin directly onto your OS via apt (Debian/Ubuntu/Mint) or"
echo "       dnf (Fedora/RHEL/Rocky/Alma)."
echo "     * Best if you specifically want a traditional system service without containers."
echo ""

INSTALL_MODE="container"
while true; do
    read -rp "$(echo -e "${BOLD}Select installation method [1-2, default 1]: ${NC}")" MODE_CHOICE
    case "${MODE_CHOICE:-1}" in
        1)
            INSTALL_MODE="container"
            ok "Selected: Rootless Podman Container"
            break
            ;;
        2)
            INSTALL_MODE="native"
            ok "Selected: Native Linux Package Install"
            break
            ;;
        *)
            err "Please enter 1 or 2."
            ;;
    esac
done

# ==============================================================================
# 6. MODE-SPECIFIC PREREQUISITE CHECKS
# ==============================================================================
APP_NAME="jellyfin"
QUADLET_DIR="${HOME}/.config/containers/systemd"

if [[ "$INSTALL_MODE" == "container" ]]; then
    # [NOTE] Verify podman, tar, curl, and loginctl are available.
    MISSING_TOOLS=()
    for cmd in podman tar curl loginctl; do
        command -v "$cmd" >/dev/null 2>&1 || MISSING_TOOLS+=("$cmd")
    done
    if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
        err "Missing required tools: ${MISSING_TOOLS[*]}"
        info "Install them with: ${BOLD}${PKG_HINT}${NC}"
        exit 1
    fi

    # [NOTE] Podman Quadlets (.container files) were introduced in Podman 4.4.
    PODMAN_VER=$(podman --version | awk '{print $3}')
    if [[ "$(printf '%s\n' "4.4.0" "$PODMAN_VER" | sort -V | head -n1)" != "4.4.0" ]]; then
        err "Podman v${PODMAN_VER} is too old. Quadlets require Podman >= 4.4.0."
        exit 1
    fi
    ok "Podman v${PODMAN_VER} ready."

    # [NOTE] Rootless containers map container UIDs to subordinate host UIDs
    #   defined in /etc/subuid and /etc/subgid.
    if ! grep -q "^${USER}:" /etc/subuid 2>/dev/null || ! grep -q "^${USER}:" /etc/subgid 2>/dev/null; then
        err "User '${USER}' lacks subordinate UID/GID ranges in /etc/subuid."
        info "Fix with: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${USER}"
        exit 1
    fi

    # [NOTE] "Lingering" lets systemd start your rootless container at boot
    #   and keep it running after you close your SSH/desktop session.
    if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo "no")" != "yes" ]]; then
        echo ""
        warn "User lingering is currently disabled for '${USER}'."
        echo "  Enabling linger allows Jellyfin to start automatically on boot and keep"
        echo "  running after you log out."
        if ask_yes_no "Enable user lingering now?" "Y"; then
            loginctl enable-linger "$USER" 2>/dev/null || sudo loginctl enable-linger "$USER" || \
                warn "Could not enable linger automatically. Run later: sudo loginctl enable-linger ${USER}"
        fi
    fi

    # Allow custom instance names in container mode (useful for side-by-side testing)
    echo ""
    while true; do
        read -rp "$(echo -e "${BOLD}Container instance name [jellyfin]: ${NC}")" APP_NAME
        APP_NAME="${APP_NAME:-jellyfin}"
        if [[ ! "$APP_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
            err "Use lowercase letters, numbers, hyphens (-), or underscores (_)."
            continue
        fi
        if [[ -f "${QUADLET_DIR}/${APP_NAME}.container" || -d "${HOME}/containers/${APP_NAME}" ]]; then
            warn "An existing '${APP_NAME}' container setup already exists."
            if ! ask_yes_no "Update/replace '${APP_NAME}' in place (keeps existing config data)?" "N"; then
                continue
            fi
        fi
        break
    done
else
    # [NOTE] Native install supports Debian/Ubuntu/Mint (via official Jellyfin
    #   extrepo/apt repo) and Fedora/RHEL/Rocky/Alma (via RPM Fusion).
    case "$OS_ID" in
        debian|ubuntu|pop|linuxmint|fedora|rhel|rocky|almalinux|centos)
            ok "Native installation is supported on ${OS_PRETTY}."
            ;;
        *)
            warn "Automated native packaging is only configured for Debian/Ubuntu and Fedora/RHEL."
            info "Please re-run and choose Option 1 (Rootless Podman Container), which works on all distros!"
            exit 0
            ;;
    esac
fi

# ==============================================================================
# 7. MEDIA FOLDER & NETWORK SHARE (NFS / SAMBA) DETECTION
# ==============================================================================
# [NOTE] Detecting whether media lives on a local drive, NFS share, or Samba/SMB
#   share prevents permission failures and avoids Podman's ":Z" SELinux relabel
#   flag from failing on network filesystems that don't support extended attributes.
echo -e "\n${BOLD}--- Media Storage Setup ---${NC}"

ACTIVE_NET_MOUNTS=$(findmnt -rn -t nfs,nfs4,cifs,smb3 -o TARGET,FSTYPE 2>/dev/null || true)
if [[ -n "$ACTIVE_NET_MOUNTS" ]]; then
    info "Detected active network shares on this system:"
    while IFS= read -r line; do
        echo "    -> $line"
    done <<< "$ACTIVE_NET_MOUNTS"
fi

DEFAULT_MEDIA="/mnt/media/data"
while true; do
    echo ""
    read -rp "$(echo -e "${BOLD}Path to your media folder [${DEFAULT_MEDIA}]: ${NC}")" MEDIA_PATH
    MEDIA_PATH="${MEDIA_PATH:-$DEFAULT_MEDIA}"
    MEDIA_PATH="${MEDIA_PATH%/}"

    if [[ ! -d "$MEDIA_PATH" ]]; then
        warn "Folder '${MEDIA_PATH}' does not exist yet."
        if ask_yes_no "Create '${MEDIA_PATH}' now?" "N"; then
            mkdir -p "$MEDIA_PATH" 2>/dev/null || sudo mkdir -p "$MEDIA_PATH"
        else
            continue
        fi
    fi

    # [NOTE] Mounting a top-level mount point (like /mnt/nas directly instead of
    #   /mnt/nas/media) can cause Jellyfin to think your library was deleted if
    #   the network drive ever disconnects temporarily.
    if mountpoint -q "$MEDIA_PATH"; then
        warn "'${MEDIA_PATH}' is a top-level mount point."
        warn "Using a subfolder (e.g., ${MEDIA_PATH}/movies) protects your library metadata"
        warn "if a network or USB drive temporarily disconnects."
        if ! ask_yes_no "Use '${MEDIA_PATH}' anyway?" "N"; then
            continue
        fi
    fi
    break
done

MEDIA_FSTYPE=$(stat -f -c %T "$MEDIA_PATH" 2>/dev/null || echo "unknown")
MEDIA_VOL_OPTS=""

case "$MEDIA_FSTYPE" in
    nfs*)
        ok "Detected NFS share (${MEDIA_FSTYPE}) -> omitting :Z relabel."
        if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
            if command -v getsebool >/dev/null 2>&1 && ! getsebool virt_use_nfs 2>/dev/null | grep -q "on$"; then
                warn "SELinux is Enforcing. Run: sudo setsebool -P virt_use_nfs 1"
            fi
        fi
        ;;
    cifs|smb*)
        ok "Detected Samba/SMB share (${MEDIA_FSTYPE}) -> omitting :Z relabel."
        warn "Tip: Make sure your SMB mount in /etc/fstab includes 'uid=$(id -u),gid=$(id -g)'"
        warn "     so Jellyfin can read your media files cleanly."
        ;;
    ext2/ext3|ext4|btrfs|xfs|zfs|tmpfs|overlayfs)
        MEDIA_VOL_OPTS=":Z"
        ok "Detected local filesystem (${MEDIA_FSTYPE}) -> using :Z label."
        ;;
    *)
        warn "Could not auto-detect storage type ('${MEDIA_FSTYPE}') for '${MEDIA_PATH}'."
        echo "  1) Local drive (ext4, btrfs, xfs, zfs)"
        echo "  2) Samba / SMB network share (cifs)"
        echo "  3) NFS network share"
        read -rp "$(echo -e "${BOLD}Select storage type [1-3, default 1]: ${NC}")" STORAGE_CHOICE
        case "${STORAGE_CHOICE:-1}" in
            2) MEDIA_FSTYPE="smb"; ok "Configured for Samba/SMB." ;;
            3) MEDIA_FSTYPE="nfs"; ok "Configured for NFS." ;;
            *) MEDIA_FSTYPE="local"; MEDIA_VOL_OPTS=":Z"; ok "Configured for local drive." ;;
        esac
        ;;
esac

# ==============================================================================
# 8. PORT & OPTIONAL HARDWARE ACCELERATION
# ==============================================================================
JELLYFIN_PORT="8096"
ENABLE_GPU=false

if [[ "$INSTALL_MODE" == "container" ]]; then
    while true; do
        echo ""
                read -rp "$(echo -e "${BOLD}Web UI port for ${APP_NAME} [default 8096]: ${NC}")" JELLYFIN_PORT

        JELLYFIN_PORT="${JELLYFIN_PORT:-8096}"
        if [[ ! "$JELLYFIN_PORT" =~ ^[0-9]+$ ]] || (( JELLYFIN_PORT < 1024 || JELLYFIN_PORT > 65535 )); then
            err "Enter a valid port between 1024 and 65535."
            continue
        fi
        if ss -tln 2>/dev/null | grep -qE ":${JELLYFIN_PORT} "; then
            warn "Port ${JELLYFIN_PORT} is already in use on this machine!"
            if ! ask_yes_no "Use port ${JELLYFIN_PORT} anyway?" "N"; then
                continue
            fi
        fi
        break
    done
fi

# [NOTE] /dev/dri exposes Linux Direct Rendering Infrastructure (Intel QuickSync,
#   AMD VCN/VA-API). Passing it into the container lets Jellyfin transcode video
#   on the GPU instead of maxing out your CPU.
if [[ -d /dev/dri ]]; then
    echo ""
    info "GPU hardware rendering device (/dev/dri) detected."
    echo "  Recommended for Intel 8th Gen+ CPUs or AMD Ryzen/Radeon GPUs."
    if ask_yes_no "Enable GPU hardware transcoding?" "Y"; then
        ENABLE_GPU=true
        USER_GROUPS=$(id -nG "$USER")
        for grp in render video; do
            if getent group "$grp" >/dev/null 2>&1 && [[ ! " $USER_GROUPS " =~ " $grp " ]]; then
                warn "User '${USER}' is not in the '${grp}' group."
                echo "  Run: sudo usermod -aG ${grp} ${USER}  (takes effect after next login)"
            fi
        done
    fi
fi

# ==============================================================================
# 9. SUMMARY CONFIRMATION BEFORE MAKING CHANGES
# ==============================================================================
echo -e "\n${BOLD}--- Ready to Install ---${NC}"
echo "  Install Mode:  ${INSTALL_MODE}"
echo "  Instance Name: ${APP_NAME}"
echo "  Media Folder:  ${MEDIA_PATH} (${MEDIA_FSTYPE})"
echo "  Web UI Port:   ${JELLYFIN_PORT}"
echo "  GPU Accel:     ${ENABLE_GPU}"
echo ""
if ! ask_yes_no "Proceed with installation?" "Y"; then
    info "Installation cancelled. No changes were made."
    exit 0
fi

# ==============================================================================
# 10A. EXECUTE CONTAINER INSTALLATION (ROOTLESS PODMAN QUADLET)
# ==============================================================================
if [[ "$INSTALL_MODE" == "container" ]]; then
    APP_DIR="${HOME}/containers/${APP_NAME}"
    BACKUP_DIR="${HOME}/backups/${APP_NAME}"

    info "Creating folders in ~/containers/${APP_NAME}..."
    mkdir -p "$QUADLET_DIR" "${APP_DIR}/config" "${APP_DIR}/cache" "$BACKUP_DIR"

    GPU_BLOCK=""
    if [[ "$ENABLE_GPU" == true ]]; then
        # [NOTE] GroupAdd=keep-groups passes your host's video/render group
        #   permissions into the rootless container so /dev/dri is accessible.
        GPU_BLOCK=$'# GPU Hardware Transcoding\nAddDevice=/dev/dri:/dev/dri\nGroupAdd=keep-groups'
    fi

    # [NOTE] Quadlet files (.container) let systemd manage Podman containers
    #   natively. Restart=on-failure ensures crashes auto-recover while manual
    #   stops in Podman Desktop or systemctl stay stopped.
    info "Writing Podman Quadlet: ${QUADLET_DIR}/${APP_NAME}.container"
    cat > "${QUADLET_DIR}/${APP_NAME}.container" <<EOF
[Unit]
Description=Jellyfin Media Server (${APP_NAME})
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/jellyfin/jellyfin:latest
ContainerName=${APP_NAME}
AutoUpdate=registry
Timezone=local

PublishPort=${JELLYFIN_PORT}:8096

Volume=%h/containers/${APP_NAME}/config:/config:Z
Volume=%h/containers/${APP_NAME}/cache:/cache:Z
Volume=${MEDIA_PATH}:/media${MEDIA_VOL_OPTS}

${GPU_BLOCK}

[Service]
Restart=on-failure
TimeoutStartSec=300
Nice=10

[Install]
WantedBy=default.target
EOF

    info "Reloading systemd and starting ${APP_NAME}.service (pulling image on first run)..."
    systemctl --user daemon-reload
    systemctl --user start "${APP_NAME}.service"

# ==============================================================================
# 10B. EXECUTE NATIVE INSTALLATION (DEBIAN/UBUNTU OR FEDORA/RHEL)
# ==============================================================================
else
    info "Installing Jellyfin natively on ${OS_PRETTY} (requires sudo)..."
    if [[ "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" || "$OS_ID" == "pop" || "$OS_ID" == "linuxmint" ]]; then
        sudo apt-get update
        sudo apt-get install -y curl gnupg extrepo acl
        sudo extrepo enable jellyfin
        sudo apt-get update
        sudo apt-get install -y jellyfin
    else
        # Fedora / RHEL / Rocky / Alma via RPM Fusion
        EL_VER=$(rpm -E %rhel 2>/dev/null || echo "")
        if [[ "$OS_ID" == "fedora" ]]; then
            FED_VER=$(rpm -E %fedora)
            sudo dnf install -y \
                "https://rpmfusion.org{FED_VER}.noarch.rpm" \
                "https://rpmfusion.org{FED_VER}.noarch.rpm"
        elif [[ -n "$EL_VER" ]]; then
            sudo dnf install -y epel-release
            sudo dnf install -y \
                "https://rpmfusion.org{EL_VER}.noarch.rpm" \
                "https://rpmfusion.org{EL_VER}.noarch.rpm"
        fi
        sudo dnf install -y jellyfin acl
    fi

    # [NOTE] In native mode, Jellyfin runs under the 'jellyfin' system user.
    #   Using Access Control Lists (setfacl) grants the jellyfin user read/execute
    #   access to your media folder without changing folder ownership away from you.
    if [[ "$MEDIA_FSTYPE" != "nfs"* && "$MEDIA_FSTYPE" != "cifs" && "$MEDIA_FSTYPE" != "smb"* ]]; then
        info "Granting 'jellyfin' user read access to ${MEDIA_PATH} via ACL..."
        sudo setfacl -R -m u:jellyfin:rx "$MEDIA_PATH" 2>/dev/null || \
            warn "Could not set ACL on ${MEDIA_PATH}. Ensure the 'jellyfin' user has read permissions."
        sudo setfacl -R -d -m u:jellyfin:rx "$MEDIA_PATH" 2>/dev/null || true
    else
        warn "Network share detected: ensure mount options allow the 'jellyfin' user to read ${MEDIA_PATH}."
    fi

    # [NOTE] Add the 'jellyfin' system user to video/render groups if GPU hardware
    #   transcoding was requested.
    if [[ "$ENABLE_GPU" == true ]]; then
        for grp in render video; do
            if getent group "$grp" >/dev/null 2>&1; then
                sudo usermod -aG "$grp" jellyfin
            fi
        done
    fi

    info "Enabling and starting system jellyfin.service..."
    sudo systemctl enable --now jellyfin.service
fi

# ==============================================================================
# 11. WRITE SIMPLE RESTORE & CLEANUP GUIDE (HOW_TO_RESTORE.txt)
# ==============================================================================
mkdir -p "${HOME}/backups/${APP_NAME}"
if [[ "$INSTALL_MODE" == "container" ]]; then
    RESTORE_STEPS="     systemctl --user stop ${APP_NAME}.service
     mv ~/containers/${APP_NAME}/config ~/containers/${APP_NAME}/config.old
     tar -xzf /path/to/${APP_NAME}_YYYY-MM-DD_HHMM.tar.gz -C ~/containers/${APP_NAME}/
     systemctl --user start ${APP_NAME}.service"
else
    RESTORE_STEPS="     sudo systemctl stop jellyfin.service
     sudo mv /var/lib/jellyfin /var/lib/jellyfin.old
     sudo tar -xzf /path/to/${APP_NAME}_YYYY-MM-DD_HHMM.tar.gz -C /var/lib/
     sudo chown -R jellyfin:jellyfin /var/lib/jellyfin
     sudo systemctl start jellyfin.service"
fi

cat > "${HOME}/backups/${APP_NAME}/HOW_TO_RESTORE.txt" <<EOF
================================================================================
JELLYFIN QUICK BACKUP, RESTORE & CLEANUP GUIDE (${APP_NAME})
================================================================================
Install Mode: ${INSTALL_MODE}
Media Path:   ${MEDIA_PATH}

1. CREATE AN ON-DEMAND BACKUP ANYTIME:
     ./$(basename "$0") --backup ${APP_NAME}
   This safely pauses Jellyfin, saves a dated .tar.gz file into:
     ${HOME}/backups/${APP_NAME}/
   and restarts Jellyfin. You can copy that .tar.gz file to your NAS or USB
   drive whenever you like.

2. RESTORE FROM A BACKUP ARCHIVE (${INSTALL_MODE} mode):
${RESTORE_STEPS}

3. POST-INSTALL CLEANUP:
   * Remove unused/old container images:   podman image prune -f
   * Clean package cache (Native mode):    sudo apt autoremove -y   (or sudo dnf clean all)
   * Uninstall Jellyfin cleanly anytime:   ./$(basename "$0") --uninstall ${APP_NAME}
================================================================================
EOF


# ==============================================================================
# 12. VERIFY LIVE HTTP RESPONSE & PRINT CLOSING BANNER
# ==============================================================================
info "Waiting for Jellyfin web interface on http://127.0.0.1:${JELLYFIN_PORT} ..."
READY=false
for _ in $(seq 1 45); do
    if curl -fsS "http://127.0.0.1:${JELLYFIN_PORT}/health" >/dev/null 2>&1 || \
       curl -fsS "http://127.0.0.1:${JELLYFIN_PORT}/web/index.html" >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 2
done

echo ""
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

if [[ "$READY" == true ]]; then
    ok "${BOLD}Finished creating your Jellyfin server!${NC}"
else
    warn "Jellyfin is still starting up in the background. Give it 15-30 seconds, then open:"
fi

# [NOTE] We display 127.0.0.1 explicitly instead of 'localhost' because some
#   Linux browsers resolve 'localhost' to IPv6 (::1) first while rootless
#   Podman binds to IPv4 (127.0.0.1).
echo ""
echo -e "${BOLD}Open the Jellyfin Setup Wizard in your browser:${NC}"
echo "  Local PC:      http://127.0.0.1:${JELLYFIN_PORT}"
if [[ -n "$HOST_IP" ]]; then
    echo "  Other Devices: http://${HOST_IP}:${JELLYFIN_PORT}"
fi
if [[ "$INSTALL_MODE" == "container" ]]; then
    echo "  Media Folder:  Select '/media' inside the Jellyfin library setup wizard."
else
    echo "  Media Folder:  Select '${MEDIA_PATH}' inside the Jellyfin library setup wizard."
fi

echo ""
echo -e "${BOLD}Post-Install Cleanup & Handy Commands:${NC}"
if [[ "$INSTALL_MODE" == "container" ]]; then
    echo "  * Clean unused image layers:  podman image prune -f"
    echo "  * Stop / Start server:        systemctl --user stop|start ${APP_NAME}.service"
else
    echo "  * Clean package cache:        sudo apt autoremove -y  (or sudo dnf clean all)"
    echo "  * Stop / Start server:        sudo systemctl stop|start jellyfin.service"
fi
echo "  * Create a backup anytime:    ./$(basename "$0") --backup ${APP_NAME}"
echo "  * Uninstall cleanly anytime:  ./$(basename "$0") --uninstall ${APP_NAME}"
echo "  * Recovery guide saved to:    ~/backups/${APP_NAME}/HOW_TO_RESTORE.txt"

echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  Thank you for using ${PROJECT_NAME}!${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo "  Trying out the ${PROJECT_VERSION} release? We would love to hear how"
echo "  your setup went or any ideas to make it even simpler for newcomers:"
echo -e "  ${BOLD}${FEEDBACK_URL}${NC}"
echo ""

# ==============================================================================
# 13. OPTIONAL SELF-CLEANUP
# ==============================================================================
if [[ "$KEEP_SCRIPT" == false ]]; then
    if ask_yes_no "Delete this setup script now (answer 'N' to keep it for --backup / --uninstall)?" "N"; then
        SCRIPT_PATH="$(realpath "$0")"
        rm -f "$SCRIPT_PATH"
        ok "Removed ${SCRIPT_PATH}."
    else
        info "Kept $(basename "$0") on disk."
    fi
fi
