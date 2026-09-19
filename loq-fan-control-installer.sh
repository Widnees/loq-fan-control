#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly EXPECTED_VENDOR="LENOVO"
readonly EXPECTED_PRODUCT="83GS"
readonly EXPECTED_MODEL="LOQ 15IAX9"
readonly EXPECTED_BIOS="NECN47WW"
readonly MIN_KERNEL="7.2.2"

ACTION="install"
INSTALL_PACKAGES=1
RUN_SELF_TEST=1
FORCE_UNSUPPORTED=0
TMP_DIR=""
RESTORE_AUTO_ON_EXIT=0

info() { printf '\033[1;34m[Info]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[Warning]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[Error]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Lenovo LOQ 15IAX9 fan control installer

Usage:
  bash loq-fan-control-installer.sh [option]

Options:
  --install             Install or update the existing installation (default)
  --uninstall           Remove the installed fan-control components
  --status              Show installation and fan status
  --skip-self-test      Skip the short fan test after installation
  --no-packages         Do not install missing packages automatically
  --force-unsupported   Bypass the DMI/BIOS check (not recommended)
  -h, --help            Show this help

Profiles:
  low:     approximately 900 RPM on both fans
  medium:  approximately 2900 RPM on both fans
  max:     approximately 5800 RPM on both fans
  auto:    Lenovo firmware control
EOF
}

for arg in "$@"; do
    case "$arg" in
        --install) ACTION="install" ;;
        --uninstall) ACTION="uninstall" ;;
        --status) ACTION="status" ;;
        --skip-self-test) RUN_SELF_TEST=0 ;;
        --no-packages) INSTALL_PACKAGES=0 ;;
        --force-unsupported) FORCE_UNSUPPORTED=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Unknown option: $arg" ;;
    esac
done

SCRIPT_PATH="$(readlink -f -- "$0")"

choose_target_user() {
    local candidate="${LOQ_TARGET_USER:-${SUDO_USER:-}}"
    if [[ -z "$candidate" || "$candidate" == root ]]; then
        candidate="${USER:-}"
    fi
    if [[ -z "$candidate" || "$candidate" == root ]]; then
        candidate="$(logname 2>/dev/null || true)"
    fi
    if [[ -z "$candidate" || "$candidate" == root ]]; then
        if [[ -t 0 ]]; then
            read -r -p "Desktop username for notifications: " candidate
        else
            die "Could not determine the desktop user. Set LOQ_TARGET_USER and try again."
        fi
    fi
    getent passwd "$candidate" >/dev/null || die "User not found: $candidate"
    printf '%s' "$candidate"
}

if (( EUID != 0 )); then
    TARGET_USER="$(choose_target_user)"
    info "Administrator privileges are required; user: $TARGET_USER"
    if command -v pkexec >/dev/null 2>&1; then
        exec pkexec /usr/bin/env "LOQ_TARGET_USER=$TARGET_USER" /usr/bin/bash "$SCRIPT_PATH" "$@"
    elif command -v sudo >/dev/null 2>&1; then
        exec sudo /usr/bin/env "LOQ_TARGET_USER=$TARGET_USER" /usr/bin/bash "$SCRIPT_PATH" "$@"
    else
        die "Neither pkexec nor sudo was found. Run this script from a root terminal."
    fi
fi

TARGET_USER="$(choose_target_user)"

cleanup() {
    if (( RESTORE_AUTO_ON_EXIT )) && [[ -x /usr/local/sbin/loq-fan-control ]]; then
        /usr/local/sbin/loq-fan-control auto >/dev/null 2>&1 || true
    fi
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}
trap cleanup EXIT

read_dmi() {
    local name=$1
    tr -d '\n' < "/sys/class/dmi/id/$name" 2>/dev/null || true
}

check_hardware() {
    local vendor product model bios
    vendor="$(read_dmi sys_vendor)"
    product="$(read_dmi product_name)"
    model="$(read_dmi product_version)"
    bios="$(read_dmi bios_version)"

    info "Detected device: $vendor / $product / $model / BIOS $bios"
    if [[ "$vendor" != "$EXPECTED_VENDOR" || "$product" != "$EXPECTED_PRODUCT" ||
          "$model" != "$EXPECTED_MODEL" || "$bios" != "$EXPECTED_BIOS" ]]; then
        if (( FORCE_UNSUPPORTED )); then
            warn "Hardware does not match; continuing because --force-unsupported was supplied."
        else
            die "This script is calibrated only for $EXPECTED_VENDOR $EXPECTED_PRODUCT $EXPECTED_MODEL with BIOS $EXPECTED_BIOS."
        fi
    fi
    ok "Hardware and BIOS validated"
}

version_at_least() {
    local current=$1 required=$2
    [[ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n1)" == "$required" ]]
}

check_kernel() {
    local running
    running="$(uname -r | cut -d- -f1)"
    if ! version_at_least "$running" "$MIN_KERNEL"; then
        die "Running kernel is $running; at least $MIN_KERNEL is required. Update and reboot, then run the installer again."
    fi
    ok "Kernel version is supported: $(uname -r)"
}

declare -A COMMAND_PACKAGE=(
    [python3]="python"
    [notify-send]="libnotify"
    [flock]="util-linux"
    [runuser]="util-linux"
    [modprobe]="kmod"
    [systemctl]="systemd"
    [visudo]="sudo"
)

missing_packages() {
    local command_name
    local -A seen=()
    for command_name in "${!COMMAND_PACKAGE[@]}"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            seen["${COMMAND_PACKAGE[$command_name]}"]=1
        fi
    done
    printf '%s\n' "${!seen[@]}" | sed '/^$/d' | sort
}

ensure_dependencies() {
    local -a missing=()
    mapfile -t missing < <(missing_packages)
    (( ${#missing[@]} == 0 )) && { ok "Required dependencies are installed"; return; }

    warn "Missing packages: ${missing[*]}"
    if (( INSTALL_PACKAGES )) && command -v pacman >/dev/null 2>&1; then
        info "Installing missing packages from the configured pacman repositories..."
        if pacman -S --needed --noconfirm -- "${missing[@]}"; then
            ok "Missing packages installed"
        else
            warn "Packages could not be downloaded automatically."
            printf 'Run this command manually:\n  sudo pacman -S --needed %s\n' "${missing[*]}"
            if [[ -t 0 ]]; then
                read -r -p "Press Enter after installing the packages in another terminal, or q to exit: " answer
                [[ "${answer:-}" != q && "${answer:-}" != Q ]] || exit 1
            else
                die "Dependency installation failed; install the packages manually and run the installer again."
            fi
        fi
    else
        printf 'Install these packages manually, then run the installer again: %s\n' "${missing[*]}"
        exit 1
    fi

    mapfile -t missing < <(missing_packages)
    (( ${#missing[@]} == 0 )) || die "Packages are still missing: ${missing[*]}"
}

write_payloads() {
    TMP_DIR="$(mktemp -d /tmp/loq-fan-install.XXXXXX)"

    cat > "$TMP_DIR/loq-fan-control.conf" <<'EOF'
# Calibrated with a tachometer on Lenovo LOQ 15IAX9 (83GS, NECN47WW).
# One raw step is approximately 100 RPM with relax_fan_constraint enabled.
LOW_RAW=9
LOW_RPM=900
MEDIUM_RAW=29
MEDIUM_RPM=2900
MAX_RAW=60
MAX_RPM=5800
TEMP_LIMIT_C=85
EOF

    cat > "$TMP_DIR/99-loq-fan.conf" <<'EOF'
# LOQ 15IAX9 firmware does not expose min/max fan values.
options lenovo_wmi_other expose_all_fans=1 relax_fan_constraint=1
EOF

    cat > "$TMP_DIR/loq-fan-control" <<'EOF'
#!/usr/bin/bash
set -euo pipefail

readonly STATE_FILE=/run/loq-fan-control.mode
readonly LOCK_FILE=/run/loq-fan-control.lock
readonly CONFIG_FILE=/etc/loq-fan-control.conf

LOW_RAW=9
LOW_RPM=900
MEDIUM_RAW=29
MEDIUM_RPM=2900
MAX_RAW=60
MAX_RPM=5800
TEMP_LIMIT_C=85

[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

check_model() {
    [[ $(</sys/class/dmi/id/sys_vendor) == "LENOVO" &&
       $(</sys/class/dmi/id/product_name) == "83GS" &&
       $(</sys/class/dmi/id/product_version) == "LOQ 15IAX9" &&
       $(</sys/class/dmi/id/bios_version) == "NECN47WW" ]]
}

find_hwmon() {
    local dir
    for dir in /sys/class/hwmon/hwmon*; do
        [[ -r "$dir/name" ]] || continue
        [[ $(<"$dir/name") == lenovo_wmi_other ]] || continue
        printf '%s\n' "$dir"
        return 0
    done
    return 1
}

kernel_is_safe() {
    [[ $(printf '%s\n' 7.2.2 "$(uname -r | cut -d- -f1)" | sort -V | head -n1) == 7.2.2 ]]
}

set_mode() {
    local mode=$1 raw rpm hwmon fan1 fan2
    case "$mode" in
        auto) raw=0; rpm=0 ;;
        low) raw=$LOW_RAW; rpm=$LOW_RPM ;;
        medium) raw=$MEDIUM_RAW; rpm=$MEDIUM_RPM ;;
        max) raw=$MAX_RAW; rpm=$MAX_RPM ;;
        *) printf 'Invalid mode: %s\n' "$mode" >&2; return 2 ;;
    esac

    check_model || { printf 'Device/BIOS safety check failed.\n' >&2; return 3; }
    if [[ $mode != auto ]] && ! kernel_is_safe; then
        printf 'Kernel 7.2.2 or newer is required.\n' >&2
        return 4
    fi
    hwmon=$(find_hwmon) || { printf 'The lenovo_wmi_other fan interface was not found.\n' >&2; return 5; }
    fan1="$hwmon/fan1_target"
    fan2="$hwmon/fan2_target"
    [[ -w $fan1 && -w $fan2 ]] || { printf 'Two writable fan targets were not found.\n' >&2; return 6; }

    if ! printf '%s' "$raw" > "$fan1" || ! printf '%s' "$raw" > "$fan2"; then
        printf '0' > "$fan1" 2>/dev/null || true
        printf '0' > "$fan2" 2>/dev/null || true
        printf 'Fan targets could not be written; returned to automatic mode.\n' >&2
        return 7
    fi
    printf '%s\n' "$mode" > "$STATE_FILE"
    printf '%s|%s\n' "$mode" "$rpm"
}

current_mode() {
    local saved
    if [[ -r "$STATE_FILE" ]]; then
        saved=$(<"$STATE_FILE")
        case "$saved" in auto|low|medium|max) printf '%s\n' "$saved"; return ;; esac
    fi
    printf 'auto\n'
}

cycle_mode() {
    case "$(current_mode)" in
        auto) set_mode low ;;
        low) set_mode medium ;;
        medium) set_mode max ;;
        max) set_mode auto ;;
    esac
}

status() {
    local hwmon output file
    hwmon=$(find_hwmon) || { printf 'unavailable|-\n'; return 5; }
    output="$(current_mode)|"
    for file in "$hwmon"/fan1_input "$hwmon"/fan2_input; do
        [[ -r "$file" ]] || continue
        output+="${file##*/}=$(<"$file") "
    done
    printf '%s\n' "${output% }"
}

safety_check() {
    [[ $(current_mode) != auto ]] || return 0
    local file value hottest=0 gpu_temp=0
    for file in /sys/class/hwmon/hwmon*/temp*_input; do
        [[ -r "$file" ]] || continue
        read -r value < "$file" || continue
        [[ $value =~ ^[0-9]+$ ]] || continue
        (( value <= 120000 && value > hottest )) && hottest=$value
    done
    if command -v nvidia-smi >/dev/null 2>&1; then
        gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | sort -nr | head -n1 || true)
        [[ $gpu_temp =~ ^[0-9]+$ ]] && (( gpu_temp * 1000 > hottest )) && hottest=$((gpu_temp * 1000))
    fi
    if (( hottest >= TEMP_LIMIT_C * 1000 )); then
        logger -t loq-fan-control "Temperature $((hottest / 1000))°C; returning to automatic fan mode"
        set_mode auto >/dev/null
    fi
}

exec 9>"$LOCK_FILE"
flock 9
case "${1:-}" in
    cycle) cycle_mode ;;
    auto|low|medium|max) set_mode "$1" ;;
    status) status ;;
    safety-check) safety_check ;;
    *) printf 'Usage: %s {cycle|auto|low|medium|max|status|safety-check}\n' "$0" >&2; exit 2 ;;
esac
EOF

    cat > "$TMP_DIR/loq-copilot-listener" <<'EOF'
#!/usr/bin/python3
"""Cycle the calibrated LOQ fan modes with the Copilot key."""

import glob
import os
import pwd
import struct
import subprocess

EVENT = struct.Struct("llHHi")
EV_KEY = 1
KEY_LEFTSHIFT = 42
KEY_LEFTMETA = 125
KEY_F23 = 193
COOLDOWN_SECONDS = 2.0
USER_FILE = "/etc/loq-fan-notify-user"


def notification_user():
    with open(USER_FILE, encoding="utf-8") as stream:
        username = stream.read().strip()
    pwd.getpwnam(username)
    return username


def cooldown_expired(event_time, last_trigger):
    return event_time - last_trigger >= COOLDOWN_SECONDS


def keyboard_path():
    for path in glob.glob("/dev/input/event*"):
        name_path = f"/sys/class/input/{os.path.basename(path)}/device/name"
        try:
            with open(name_path, encoding="utf-8") as stream:
                if stream.read().strip() == "ITE Tech. Inc. ITE Device(8176) Keyboard":
                    return path
        except OSError:
            continue
    raise FileNotFoundError("ITE Copilot keyboard input device not found")


def send_notification(title, detail, urgency="normal"):
    username = notification_user()
    uid = pwd.getpwnam(username).pw_uid
    runtime = f"/run/user/{uid}"
    bus = f"{runtime}/bus"
    if not os.path.exists(bus):
        return
    subprocess.run(
        [
            "/usr/bin/runuser", "-u", username, "--", "/usr/bin/env",
            f"XDG_RUNTIME_DIR={runtime}",
            f"DBUS_SESSION_BUS_ADDRESS=unix:path={bus}",
            "/usr/bin/notify-send", "-u", urgency, "-t", "3000",
            "-a", "LOQ Fan", "-i", "preferences-system-power-management",
            title, detail,
        ],
        check=False,
    )


def notify_mode(result):
    mode, rpm = result.strip().split("|", 1)
    messages = {
        "auto": ("Fan mode: Automatic", "Lenovo automatic fan control enabled"),
        "low": ("Fan mode: Low", f"Both fan targets: {rpm} RPM"),
        "medium": ("Fan mode: Medium", f"Both fan targets: {rpm} RPM"),
        "max": ("Fan mode: Maximum", f"Both fan targets: {rpm} RPM"),
    }
    title, detail = messages.get(mode, (f"Fan modu: {mode}", f"Hedef: {rpm} RPM"))
    send_notification(title, detail)


def main():
    path = keyboard_path()
    print(f"Listening for the Copilot input device: {path}", flush=True)
    fd = os.open(path, os.O_RDONLY)
    meta = False
    shift = False
    last_trigger = float("-inf")
    while True:
        data = os.read(fd, EVENT.size * 32)
        for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
            event_sec, event_usec, event_type, code, value = EVENT.unpack_from(data, offset)
            if event_type != EV_KEY:
                continue
            if code == KEY_LEFTMETA:
                meta = value != 0
            elif code == KEY_LEFTSHIFT:
                shift = value != 0
            elif code == KEY_F23 and value == 1:
                event_time = event_sec + event_usec / 1_000_000
                since_last = event_time - last_trigger
                if not cooldown_expired(event_time, last_trigger):
                    print(f"F23 cooldown: ignored ({since_last:.2f}s)", flush=True)
                    continue
                last_trigger = event_time
                print(f"F23 received (meta={meta}, shift={shift})", flush=True)
                try:
                    result = subprocess.run(
                        ["/usr/local/sbin/loq-fan-control", "cycle"],
                        check=True, text=True, capture_output=True,
                    )
                    print(f"Fan transition: {result.stdout.strip()}", flush=True)
                    notify_mode(result.stdout)
                except subprocess.CalledProcessError as error:
                    detail = (error.stderr or error.stdout or str(error)).strip()
                    print(f"Fan transition failed: {detail}", flush=True)
                    send_notification("LOQ fan control failed", detail, "critical")


if __name__ == "__main__":
    main()
EOF

    cat > "$TMP_DIR/loq-copilot-fan.service" <<'EOF'
[Unit]
Description=LOQ Copilot key fan mode listener
After=systemd-modules-load.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/loq-copilot-listener
Restart=on-failure
RestartSec=2s
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    cat > "$TMP_DIR/loq-fan-safety.service" <<'EOF'
[Unit]
Description=LOQ manual fan temperature safety check
ConditionPathExists=/sys/module/lenovo_wmi_other

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/loq-fan-control safety-check
EOF

    cat > "$TMP_DIR/loq-fan-safety.timer" <<'EOF'
[Unit]
Description=Check LOQ temperatures while a manual fan mode is active

[Timer]
OnBootSec=15s
OnUnitActiveSec=5s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

    cat > "$TMP_DIR/loq-fan-control.sudoers" <<EOF
$TARGET_USER ALL=(root) NOPASSWD: /usr/local/sbin/loq-fan-control cycle, /usr/local/sbin/loq-fan-control auto, /usr/local/sbin/loq-fan-control low, /usr/local/sbin/loq-fan-control medium, /usr/local/sbin/loq-fan-control max, /usr/local/sbin/loq-fan-control status
EOF

    printf '%s\n' "$TARGET_USER" > "$TMP_DIR/loq-fan-notify-user"

    chmod 0755 "$TMP_DIR/loq-fan-control" "$TMP_DIR/loq-copilot-listener"
    chmod 0644 "$TMP_DIR/loq-fan-control.conf" "$TMP_DIR/99-loq-fan.conf" \
        "$TMP_DIR/loq-copilot-fan.service" "$TMP_DIR/loq-fan-safety.service" \
        "$TMP_DIR/loq-fan-safety.timer" "$TMP_DIR/loq-fan-notify-user"
    chmod 0440 "$TMP_DIR/loq-fan-control.sudoers"

    bash -n "$TMP_DIR/loq-fan-control"
    python3 -m py_compile "$TMP_DIR/loq-copilot-listener"
    visudo -cf "$TMP_DIR/loq-fan-control.sudoers" >/dev/null
    ok "Installer payload syntax validated"
}

install_files() {
    systemctl stop loq-copilot-fan.service loq-fan-safety.timer 2>/dev/null || true
    if [[ -x /usr/local/sbin/loq-fan-control ]]; then
        /usr/local/sbin/loq-fan-control auto >/dev/null 2>&1 || true
    fi

    install -d -o root -g root -m 0755 /usr/local/sbin /etc/modprobe.d /etc/sudoers.d /etc/systemd/system
    install -o root -g root -m 0755 "$TMP_DIR/loq-fan-control" /usr/local/sbin/loq-fan-control
    install -o root -g root -m 0755 "$TMP_DIR/loq-copilot-listener" /usr/local/sbin/loq-copilot-listener
    install -o root -g root -m 0644 "$TMP_DIR/loq-fan-control.conf" /etc/loq-fan-control.conf
    install -o root -g root -m 0644 "$TMP_DIR/loq-fan-notify-user" /etc/loq-fan-notify-user
    install -o root -g root -m 0644 "$TMP_DIR/99-loq-fan.conf" /etc/modprobe.d/99-loq-fan.conf
    install -o root -g root -m 0644 "$TMP_DIR/loq-copilot-fan.service" /etc/systemd/system/loq-copilot-fan.service
    install -o root -g root -m 0644 "$TMP_DIR/loq-fan-safety.service" /etc/systemd/system/loq-fan-safety.service
    install -o root -g root -m 0644 "$TMP_DIR/loq-fan-safety.timer" /etc/systemd/system/loq-fan-safety.timer
    install -o root -g root -m 0440 "$TMP_DIR/loq-fan-control.sudoers" /etc/sudoers.d/loq-fan-control
    visudo -cf /etc/sudoers.d/loq-fan-control >/dev/null
    ok "Fan-control files installed"
}

module_parameter_enabled() {
    local file=$1
    [[ -r "$file" ]] && [[ $(<"$file") == Y || $(<"$file") == 1 ]]
}

configure_kernel_module() {
    local reload_needed=0
    modprobe lenovo_wmi_other || die "Could not load the lenovo_wmi_other module."
    module_parameter_enabled /sys/module/lenovo_wmi_other/parameters/expose_all_fans || reload_needed=1
    module_parameter_enabled /sys/module/lenovo_wmi_other/parameters/relax_fan_constraint || reload_needed=1

    if (( reload_needed )); then
        info "Reloading lenovo_wmi_other with the requested parameters..."
        if modprobe -r lenovo_wmi_other && modprobe lenovo_wmi_other expose_all_fans=1 relax_fan_constraint=1; then
            ok "Kernel module loaded with the requested parameters"
        else
            warn "The module could not be reloaded while running. The setting is persistent; a reboot is required."
            return 2
        fi
    else
        ok "Kernel fan parameters enabled"
    fi
    command -v udevadm >/dev/null 2>&1 && udevadm settle || true
    sleep 1
}

find_fan_hwmon() {
    local dir
    for dir in /sys/class/hwmon/hwmon*; do
        [[ -r "$dir/name" ]] || continue
        [[ $(<"$dir/name") == lenovo_wmi_other ]] || continue
        printf '%s\n' "$dir"
        return 0
    done
    return 1
}

self_test() {
    local hwmon mode raw seconds status target1 target2
    hwmon="$(find_fan_hwmon)" || { warn "The fan interface is not available yet; it may appear after a reboot."; return 2; }
    [[ -w "$hwmon/fan1_target" && -w "$hwmon/fan2_target" ]] || {
        warn "Two writable fan targets are unavailable; a reboot may be required."
        return 2
    }

    RESTORE_AUTO_ON_EXIT=1
    info "Starting the short fan self-test; maximum mode will be audible for a few seconds."
    for entry in "low:9:3" "medium:29:3" "max:60:5"; do
        IFS=: read -r mode raw seconds <<< "$entry"
        /usr/local/sbin/loq-fan-control "$mode" >/dev/null
        target1=$(<"$hwmon/fan1_target")
        target2=$(<"$hwmon/fan2_target")
        [[ $target1 == "$raw" && $target2 == "$raw" ]] || die "$mode target test failed: $target1/$target2"
        sleep "$seconds"
        status=$(/usr/local/sbin/loq-fan-control status)
        info "$mode test: $status"
    done
    /usr/local/sbin/loq-fan-control auto >/dev/null
    [[ $(<"$hwmon/fan1_target") == 0 && $(<"$hwmon/fan2_target") == 0 ]] || die "Could not verify the return to automatic mode."
    sleep 4
    RESTORE_AUTO_ON_EXIT=0
    ok "Low, medium, maximum, and automatic target tests passed"
}

enable_services() {
    systemctl daemon-reload
    systemctl enable --now loq-fan-safety.timer
    systemctl enable --now loq-copilot-fan.service
    systemctl is-active --quiet loq-fan-safety.timer || die "The temperature safety timer did not start."
    systemctl is-active --quiet loq-copilot-fan.service || die "The Copilot key service did not start."
    ok "Copilot and temperature safety services enabled"
}

show_status() {
    local hwmon
    printf '\nLOQ fan control status\n'
    printf '  Script version: %s\n' "$SCRIPT_VERSION"
    printf '  Kernel: %s\n' "$(uname -r)"
    printf '  User: %s\n' "$TARGET_USER"
    if [[ -x /usr/local/sbin/loq-fan-control ]]; then
        printf '  Fan: %s\n' "$(/usr/local/sbin/loq-fan-control status 2>&1 || true)"
    else
        printf '  Fan: not installed\n'
    fi
    if hwmon="$(find_fan_hwmon 2>/dev/null)" &&
       [[ -r "$hwmon/fan1_target" && -r "$hwmon/fan2_target" ]]; then
        printf '  WMI targets (raw): %s / %s\n' "$(<"$hwmon/fan1_target")" "$(<"$hwmon/fan2_target")"
    fi
    printf '  Copilot servisi: %s\n' "$(systemctl is-active loq-copilot-fan.service 2>/dev/null || true)"
    printf '  Safety timer: %s\n' "$(systemctl is-active loq-fan-safety.timer 2>/dev/null || true)"
    if module_parameter_enabled /sys/module/lenovo_wmi_other/parameters/expose_all_fans &&
       module_parameter_enabled /sys/module/lenovo_wmi_other/parameters/relax_fan_constraint; then
        printf '  Kernel fan parameters: enabled\n'
    else
        printf '  Kernel fan parameters: disabled or reboot required\n'
    fi
}

uninstall_all() {
    info "Returning fans to automatic mode and removing services..."
    [[ -x /usr/local/sbin/loq-fan-control ]] && /usr/local/sbin/loq-fan-control auto >/dev/null 2>&1 || true
    systemctl disable --now loq-copilot-fan.service loq-fan-safety.timer 2>/dev/null || true
    rm -f -- \
        /usr/local/sbin/loq-fan-control \
        /usr/local/sbin/loq-copilot-listener \
        /etc/loq-fan-control.conf \
        /etc/loq-fan-notify-user \
        /etc/modprobe.d/99-loq-fan.conf \
        /etc/sudoers.d/loq-fan-control \
        /etc/systemd/system/loq-copilot-fan.service \
        /etc/systemd/system/loq-fan-safety.service \
        /etc/systemd/system/loq-fan-safety.timer
    systemctl daemon-reload
    systemctl reset-failed >/dev/null 2>&1 || true
    rm -f -- /run/loq-fan-control.mode /run/loq-fan-control.lock
    ok "Fan-control components removed. Reboot to fully reset the kernel-module parameters."
}

case "$ACTION" in
    status)
        check_hardware
        show_status
        ;;
    uninstall)
        check_hardware
        uninstall_all
        ;;
    install)
        check_hardware
        check_kernel
        ensure_dependencies
        write_payloads
        install_files
        REBOOT_NEEDED=0
        configure_kernel_module || REBOOT_NEEDED=1
        enable_services
        if (( RUN_SELF_TEST && ! REBOOT_NEEDED )); then
            self_test || REBOOT_NEEDED=1
        fi
        /usr/local/sbin/loq-fan-control auto >/dev/null 2>&1 || true
        show_status
        printf '\n'
        if (( REBOOT_NEEDED )); then
            warn "Installation completed, but reboot the computer to activate the fan interface."
            warn "After rebooting, run this installer again with --status."
        else
            ok "Installation and self-test completed; no reboot is required."
        fi
        printf 'Copilot key cycle: Automatic → Low (900) → Medium (2900) → Maximum (5800) → Automatic\n'
        ;;
esac
