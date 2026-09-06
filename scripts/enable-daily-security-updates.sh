#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"
RUN_NOW=0
ALLOW_PROXMOX=0
BACKUP_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [options]

Configure daily, security-only operating-system updates.
Automatic reboot is always disabled.

Options:
  --run-now        Install available security updates after configuration
  --allow-proxmox  Allow configuration on a Proxmox VE host (not recommended)
  -h, --help       Show this help
EOF
}

log() {
    printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

backup_file() {
    local file="$1"
    if [[ -f "$file" && ! -e "${file}.before-security-updates-${BACKUP_STAMP}" ]]; then
        cp -a -- "$file" "${file}.before-security-updates-${BACKUP_STAMP}"
    fi
}

set_ini_value() {
    local file="$1" section="$2" key="$3" value="$4" temporary
    temporary="$(mktemp "${file##*/}.XXXXXX")"

    awk -v target_section="$section" -v target_key="$key" -v target_value="$value" '
        BEGIN { in_target = 0; section_seen = 0; key_written = 0 }

        /^\[[^]]+\][[:space:]]*$/ {
            if (in_target && !key_written) {
                print target_key " = " target_value
                key_written = 1
            }

            current = $0
            gsub(/^[[:space:]]*\[/, "", current)
            gsub(/\][[:space:]]*$/, "", current)
            in_target = (current == target_section)
            if (in_target) {
                section_seen = 1
                key_written = 0
            }
            print
            next
        }

        in_target && $0 ~ "^[[:space:]]*" target_key "[[:space:]]*=" {
            if (!key_written) {
                print target_key " = " target_value
                key_written = 1
            }
            next
        }

        { print }

        END {
            if (in_target && !key_written) {
                print target_key " = " target_value
                key_written = 1
            }
            if (!section_seen) {
                print ""
                print "[" target_section "]"
                print target_key " = " target_value
            }
        }
    ' "$file" > "$temporary"

    cat "$temporary" > "$file"
    rm -f -- "$temporary"
}

unit_exists() {
    systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q "^$1"
}

configure_dnf() {
    local config="/etc/dnf/automatic.conf" timer=""

    log "Installing dnf-automatic"
    dnf install -y dnf-automatic
    [[ -f "$config" ]] || die "$config was not created by the package"
    backup_file "$config"

    set_ini_value "$config" commands upgrade_type security
    set_ini_value "$config" commands random_sleep 3600
    set_ini_value "$config" commands download_updates yes
    set_ini_value "$config" commands apply_updates yes
    set_ini_value "$config" commands reboot never
    set_ini_value "$config" emitters emit_via stdio

    # The generic timer follows /etc/dnf/automatic.conf, including security-only.
    if unit_exists dnf-automatic.timer; then
        timer="dnf-automatic.timer"
    elif unit_exists dnf-automatic-install.timer; then
        timer="dnf-automatic-install.timer"
    else
        die "No dnf-automatic systemd timer was installed"
    fi

    systemctl enable --now "$timer"
    systemctl is-enabled --quiet "$timer"
    systemctl is-active --quiet "$timer"
    log "Enabled $timer; next run: $(systemctl list-timers "$timer" --no-legend 2>/dev/null | head -n 1 || true)"

    if (( RUN_NOW )); then
        log "Installing currently available security updates"
        dnf -y upgrade --security
    fi
}

configure_yum() {
    local config="/etc/yum/yum-cron.conf"

    log "Installing yum-cron"
    yum install -y yum-cron
    [[ -f "$config" ]] || die "$config was not created by the package"
    backup_file "$config"

    set_ini_value "$config" commands update_cmd security
    set_ini_value "$config" commands random_sleep 60
    set_ini_value "$config" commands update_messages yes
    set_ini_value "$config" commands download_updates yes
    set_ini_value "$config" commands apply_updates yes

    systemctl enable --now yum-cron.service
    systemctl is-enabled --quiet yum-cron.service
    systemctl is-active --quiet yum-cron.service
    log "Enabled yum-cron.service"

    if (( RUN_NOW )); then
        log "Installing currently available security updates"
        yum -y update --security
    fi
}

configure_apt() {
    local periodic="/etc/apt/apt.conf.d/20auto-upgrades"
    local origins="/etc/apt/apt.conf.d/51security-auto-update-origins"
    local policy="/etc/apt/apt.conf.d/52security-auto-update-policy"

    export DEBIAN_FRONTEND=noninteractive
    log "Refreshing APT metadata"
    apt-get update
    log "Installing unattended-upgrades"
    apt-get install -y unattended-upgrades apt-listchanges

    backup_file "$periodic"
    backup_file "$origins"
    backup_file "$policy"

    tee "$periodic" >/dev/null <<'EOF'
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    if [[ "$OS_ID" == "ubuntu" || " $OS_LIKE " == *" ubuntu "* ]]; then
        tee "$origins" >/dev/null <<'EOF'
// Restrict unattended upgrades to Ubuntu security repositories.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Ubuntu,archive=${distro_codename}-security,label=Ubuntu";
    "origin=UbuntuESMApps,archive=${distro_codename}-apps-security,label=UbuntuESMApps";
    "origin=UbuntuESM,archive=${distro_codename}-infra-security,label=UbuntuESM";
};
EOF
    else
        tee "$origins" >/dev/null <<'EOF'
// Restrict unattended upgrades to Debian security repositories.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,archive=${distro_codename}-security,label=Debian-Security";
};
EOF
    fi

    tee "$policy" >/dev/null <<'EOF'
// Local policy installed by enable-daily-security-updates.sh
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
EOF

    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
    systemctl is-enabled --quiet apt-daily-upgrade.timer
    systemctl is-active --quiet apt-daily-upgrade.timer
    log "Enabled apt-daily-upgrade.timer; next run: $(systemctl list-timers apt-daily-upgrade.timer --no-legend 2>/dev/null | head -n 1 || true)"

    if (( RUN_NOW )); then
        log "Installing currently available unattended security updates"
        unattended-upgrade -v
    else
        log "Configuration check"
        unattended-upgrade --dry-run >/dev/null
    fi
}

while (( $# )); do
    case "$1" in
        --run-now)
            RUN_NOW=1
            ;;
        --allow-proxmox)
            ALLOW_PROXMOX=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown option: $1"
            ;;
    esac
    shift
done

[[ "${EUID}" -eq 0 ]] || die "Run this script as root"
[[ -r /etc/os-release ]] || die "Cannot detect the operating system: /etc/os-release is missing"
command -v systemctl >/dev/null 2>&1 || die "This script requires systemd"

# shellcheck disable=SC1091
source /etc/os-release
OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
OS_VERSION="${VERSION_ID:-unknown}"

log "Detected ${PRETTY_NAME:-$OS_ID $OS_VERSION}"

if { command -v pveversion >/dev/null 2>&1 || [[ -f /etc/pve/.version ]]; } && (( ! ALLOW_PROXMOX )); then
    die "Proxmox VE detected. Use a controlled maintenance workflow, or rerun with --allow-proxmox if you accept the risk"
fi

case " $OS_ID $OS_LIKE " in
    *" debian "*|*" ubuntu "*)
        configure_apt
        ;;
    *" rhel "*|*" fedora "*|*" centos "*)
        if command -v dnf >/dev/null 2>&1; then
            configure_dnf
        elif command -v yum >/dev/null 2>&1; then
            log "WARNING: yum-cron is used on this older system. Confirm that the OS vendor still supplies security updates."
            configure_yum
        else
            die "Neither dnf nor yum is available"
        fi
        ;;
    *)
        die "Unsupported operating system: ID=$OS_ID ID_LIKE=$OS_LIKE"
        ;;
esac

log "Daily security updates are configured successfully"
log "Automatic reboot is disabled"

if [[ -f /var/run/reboot-required ]]; then
    log "NOTICE: A reboot is currently required"
elif command -v needs-restarting >/dev/null 2>&1 && ! needs-restarting -r >/dev/null 2>&1; then
    log "NOTICE: A reboot is currently required"
else
    log "No reboot requirement was detected"
fi
