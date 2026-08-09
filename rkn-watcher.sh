#!/usr/bin/env bash
set -euo pipefail

VERSION="3.1.0"
APP_NAME="RKN Watcher"

INSTALL_DIR="/opt/rkn-watcher"
CONFIG_DIR="/etc/rkn-watcher"
DATA_DIR="/var/lib/rkn-watcher"
CACHE_DIR="$DATA_DIR/cache"
COUNTRY_CACHE_DIR="$CACHE_DIR/countries"
STATE_DIR="$DATA_DIR/state"
LOCK_DIR="$DATA_DIR/locks"
LOG_DIR="/var/log/rkn-watcher"

MAIN_SCRIPT="$INSTALL_DIR/rkn-watcher.sh"
CONFIG_TOOL="$INSTALL_DIR/config_tool.py"
GEOIP_APPLY_SCRIPT="$INSTALL_DIR/geoip_apply.py"
BIN_PATH="/usr/local/bin/rkn-watcher"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CONFIG_TOOL="$SCRIPT_DIR/config_tool.py"
SOURCE_GEOIP_APPLY="$SCRIPT_DIR/geoip_apply.py"

SETTINGS_FILE="$CONFIG_DIR/settings.conf"
WHITELIST_FILE="$CONFIG_DIR/whitelist.json"
BLACKLIST_FILE="$CONFIG_DIR/blacklist.json"
IPSET_STATE_FILE="$STATE_DIR/ipset.conf"
UPDATE_LOCK_FILE="$LOCK_DIR/update.lock"
UPDATE_LOG="$LOG_DIR/update.log"
ACTION_LOG="$LOG_DIR/actions.log"
GEOIP_LOG="$LOG_DIR/geoip.log"

BOOT_SERVICE="/etc/systemd/system/rkn-watcher-boot.service"
UPDATE_SERVICE="/etc/systemd/system/rkn-watcher-update.service"
UPDATE_TIMER="/etc/systemd/system/rkn-watcher-update.timer"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

MANAGED_IPSETS=(TSPUIPS GOVIPS GEOIP_ALLOW_IPS GEOIP_DENY_IPS GEOIP_COUNTRIES_ALLOW)

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR]${NC} $*"; }
title() { echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"; }
subtitle() { echo -e "${MAGENTA}───────────────────────────────────────────────────────────────${NC}"; }

ensure_dirs() {
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" "$CACHE_DIR" "$COUNTRY_CACHE_DIR" "$STATE_DIR" "$LOCK_DIR" "$LOG_DIR"
}

log_line() {
    local file=$1
    shift
    ensure_dirs
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$file"
}

log_action() { log_line "$ACTION_LOG" "$*"; }
log_update() { log_line "$UPDATE_LOG" "$*"; }

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "Скрипт должен запускаться от root"
        exit 1
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_commands() {
    local missing=0
    for cmd in "$@"; do
        if ! command_exists "$cmd"; then
            error "Не найдена команда: $cmd"
            missing=1
        fi
    done
    return $missing
}

normalize_yesno() {
    case "${1:-n}" in
        y|Y|yes|YES|Yes) echo "y" ;;
        *) echo "n" ;;
    esac
}

validate_country_code() {
    [[ ${1:-} =~ ^[A-Za-z]{2}$ ]]
}

validate_ports_csv() {
    python3 - "$1" <<'PY'
import sys
value = sys.argv[1].strip()
if value == 'all':
    sys.exit(0)
if not value:
    sys.exit(1)
parts = [p.strip() for p in value.split(',') if p.strip()]
if not parts:
    sys.exit(1)
seen = set()
for part in parts:
    if not part.isdigit():
        sys.exit(1)
    port = int(part)
    if port < 1 or port > 65535:
        sys.exit(1)
    seen.add(port)
sys.exit(0)
PY
}

validate_single_port() {
    python3 - "$1" <<'PY'
import sys
value = sys.argv[1].strip()
if not value.isdigit():
    sys.exit(1)
port = int(value)
sys.exit(0 if 1 <= port <= 65535 else 1)
PY
}

normalize_ports_csv() {
    python3 - "$1" <<'PY'
import sys
value = sys.argv[1].strip()
if not value or value == 'all':
    print('all')
    raise SystemExit(0)
ports = sorted({int(p.strip()) for p in value.split(',') if p.strip()})
print(','.join(str(p) for p in ports))
PY
}

validate_ip_or_cidr() {
    python3 - "$1" <<'PY'
import ipaddress, sys
value = sys.argv[1].strip()
try:
    if '/' in value:
        parsed = ipaddress.ip_network(value, strict=False)
    else:
        parsed = ipaddress.ip_address(value)
    if parsed.version != 4:
        raise ValueError("IPv6 is not supported")
except Exception:
    raise SystemExit(1)
PY
}

normalize_ip_or_cidr() {
    python3 - "$1" <<'PY'
import ipaddress, sys
value = sys.argv[1].strip()
if '/' in value:
    print(ipaddress.ip_network(value, strict=False))
else:
    print(ipaddress.ip_address(value))
PY
}

get_setting() {
    local key=$1
    local default=${2:-}
    if [[ -f "$SETTINGS_FILE" ]]; then
        local line
        line=$(grep -E "^${key}=" "$SETTINGS_FILE" 2>/dev/null | tail -n1 || true)
        if [[ -n "$line" ]]; then
            line=${line#*=}
            line=${line#\"}
            line=${line%\"}
            printf '%s\n' "$line"
            return 0
        fi
    fi
    printf '%s\n' "$default"
}

set_setting() {
    local key=$1
    local value=$2
    ensure_dirs
    python3 - "$SETTINGS_FILE" "$key" "$value" <<'PY'
import os, sys, tempfile
path, key, value = sys.argv[1:4]
os.makedirs(os.path.dirname(path), exist_ok=True)
lines = []
if os.path.exists(path):
    with open(path, 'r', encoding='utf-8') as fh:
        lines = fh.read().splitlines()
out = []
found = False
for line in lines:
    if line.startswith(f'{key}='):
        out.append(f'{key}="{value}"')
        found = True
    else:
        out.append(line)
if not found:
    out.append(f'{key}="{value}"')
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix='.settings.', text=True)
with os.fdopen(fd, 'w', encoding='utf-8') as fh:
    fh.write('\n'.join(out).rstrip() + '\n')
os.replace(tmp, path)
PY
}

is_installed() {
    [[ -f "$MAIN_SCRIPT" && -f "$CONFIG_TOOL" && -f "$GEOIP_APPLY_SCRIPT" ]]
}

write_default_settings_if_missing() {
    ensure_dirs
    [[ -f "$SETTINGS_FILE" ]] || cat > "$SETTINGS_FILE" <<'EOF'
FILTER_PORTS="all"
LOG_RST="n"
AUTO_UPDATE="y"
ENABLE_TSPUBLOCK="y"
ENABLE_GOVIPS="y"
EOF
}

write_default_json_if_missing() {
    ensure_dirs
    [[ -f "$WHITELIST_FILE" ]] || cat > "$WHITELIST_FILE" <<'EOF'
{
    "enabled": false,
    "countries": [],
    "ips": [],
    "ports": []
}
EOF

    [[ -f "$BLACKLIST_FILE" ]] || cat > "$BLACKLIST_FILE" <<'EOF'
{
    "ips": [],
    "ports": []
}
EOF
}

copy_helper_scripts() {
    ensure_dirs
    if [[ ! -f "$SOURCE_CONFIG_TOOL" ]]; then
        error "Не найден helper-файл: $SOURCE_CONFIG_TOOL"
        exit 1
    fi
    if [[ ! -f "$SOURCE_GEOIP_APPLY" ]]; then
        error "Не найден helper-файл: $SOURCE_GEOIP_APPLY"
        exit 1
    fi
    cp "$SOURCE_CONFIG_TOOL" "$CONFIG_TOOL"
    cp "$SOURCE_GEOIP_APPLY" "$GEOIP_APPLY_SCRIPT"
    chmod +x "$CONFIG_TOOL" "$GEOIP_APPLY_SCRIPT"
}

normalize_existing_json_files() {
    "$CONFIG_TOOL" show whitelist >/dev/null
    "$CONFIG_TOOL" show blacklist >/dev/null
}

install_dependencies() {
    if [[ "${RKN_SKIP_DEP_INSTALL:-0}" == "1" ]]; then
        info "Установка зависимостей пропущена: зависимости уже обработаны внешним установщиком"
        return 0
    fi

    info "Установка зависимостей..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y iptables ipset curl ca-certificates python3 util-linux
}

ensure_ipset_exists() {
    local name=$1
    local type=${2:-hash:net}
    local maxelem=${3:-2000000}
    ipset create "$name" "$type" family inet maxelem "$maxelem" -exist >/dev/null 2>&1
}

ipset_count() {
    local name=$1
    ipset list "$name" 2>/dev/null | awk -F': ' '/Number of entries/ {print $2; found=1} END {if (!found) print 0}'
}

remove_rule_all() {
    local chain=$1
    shift
    while iptables -C "$chain" "$@" >/dev/null 2>&1; do
        iptables -D "$chain" "$@" >/dev/null 2>&1 || break
    done
}

ensure_chain() {
    local chain=$1
    iptables -N "$chain" >/dev/null 2>&1 || true
    iptables -F "$chain" >/dev/null 2>&1 || true
}

setup_tspublock_rules() {
    local enabled log_rst
    enabled=$(get_setting ENABLE_TSPUBLOCK y)
    log_rst=$(get_setting LOG_RST n)

    ensure_ipset_exists TSPUIPS hash:net 2000000
    ensure_chain TSPUBLOCK
    remove_rule_all INPUT -j TSPUBLOCK

    if [[ "$enabled" != "y" ]]; then
        log_action "TSPUBLOCK disabled"
        return 0
    fi

    if [[ "$log_rst" == "y" ]]; then
        iptables -A TSPUBLOCK -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "TSPUBLOCK: " --log-level 4
    fi
    iptables -A TSPUBLOCK -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j DROP
    iptables -I INPUT 1 -j TSPUBLOCK
    log_action "TSPUBLOCK rules applied"
}

setup_govips_rules() {
    local enabled log_rst
    enabled=$(get_setting ENABLE_GOVIPS y)
    log_rst=$(get_setting LOG_RST n)

    ensure_ipset_exists GOVIPS hash:net 2000000
    ensure_chain GOVBLOCK
    remove_rule_all INPUT -j GOVBLOCK

    if [[ "$enabled" != "y" ]]; then
        log_action "GOVIPS disabled"
        return 0
    fi

    if [[ "$log_rst" == "y" ]]; then
        iptables -A GOVBLOCK -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -m limit --limit 5/min --limit-burst 10 -j LOG --log-prefix "GOVBLOCK: " --log-level 4
    fi
    iptables -A GOVBLOCK -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j DROP
    iptables -I INPUT 1 -j GOVBLOCK
    log_action "GOVIPS rules applied"
}

save_ipset_state() {
    ensure_dirs
    local tmp
    tmp=$(mktemp "$STATE_DIR/ipset.XXXXXX")
    : > "$tmp"
    local set_name
    for set_name in "${MANAGED_IPSETS[@]}"; do
        ipset save "$set_name" >> "$tmp" 2>/dev/null || true
    done
    mv "$tmp" "$IPSET_STATE_FILE"
}

restore_ipset_state() {
    if [[ -f "$IPSET_STATE_FILE" ]]; then
        ipset restore -exist < "$IPSET_STATE_FILE" >/dev/null 2>&1 || true
    fi
}

sanitize_tspu_file() {
    local input=$1 output=$2
    python3 - "$input" "$output" <<'PY'
import ipaddress, sys
src, dst = sys.argv[1:3]
out = []
with open(src, 'r', encoding='utf-8') as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        try:
            net = ipaddress.ip_network(line, strict=False)
        except Exception:
            continue
        if net.version == 4:
            out.append(str(net))
with open(dst, 'w', encoding='utf-8') as fh:
    for item in sorted(set(out)):
        fh.write(item + '\n')
PY
}

sanitize_gov_file() {
    local input=$1 output=$2
    python3 - "$input" "$output" <<'PY'
import ipaddress, re, sys
src, dst = sys.argv[1:3]
out = []
pattern = re.compile(r'^add\s+blacklist-v4\s+([0-9./]+)')
with open(src, 'r', encoding='utf-8') as fh:
    for raw in fh:
        line = raw.strip()
        match = pattern.match(line)
        if not match:
            continue
        try:
            net = ipaddress.ip_network(match.group(1), strict=False)
        except Exception:
            continue
        if net.version == 4:
            out.append(str(net))
with open(dst, 'w', encoding='utf-8') as fh:
    for item in sorted(set(out)):
        fh.write(item + '\n')
PY
}

replace_ipset_from_file() {
    local target=$1
    local type=$2
    local maxelem=$3
    local file=$4
    local temp="${target}_TMP"
    local restore_file count
    restore_file=$(mktemp)
    count=0

    {
        printf 'create %s %s family inet maxelem %s -exist\n' "$temp" "$type" "$maxelem"
        printf 'flush %s\n' "$temp"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            printf 'add %s %s\n' "$temp" "$line"
            count=$((count + 1))
        done < "$file"
    } > "$restore_file"

    if (( count == 0 )); then
        rm -f "$restore_file"
        return 1
    fi

    ipset restore < "$restore_file"
    rm -f "$restore_file"
    ensure_ipset_exists "$target" "$type" "$maxelem"
    ipset swap "$temp" "$target"
    ipset destroy "$temp" >/dev/null 2>&1 || true
    printf '%s\n' "$count"
}

fetch_url() {
    local url=$1 out=$2
    curl -fsSL --connect-timeout 10 --max-time 60 --retry 3 --retry-delay 2 "$url" -o "$out"
}

update_tspublock_list() {
    local raw sanitized count
    raw=$(mktemp)
    sanitized=$(mktemp)

    if ! fetch_url "https://github.com/tread-lightly/CyberOK_Skipa_ips/raw/refs/heads/main/lists/skipa_cidr.txt" "$raw"; then
        rm -f "$raw" "$sanitized"
        return 1
    fi

    if ! sanitize_tspu_file "$raw" "$sanitized"; then
        rm -f "$raw" "$sanitized"
        return 1
    fi

    rm -f "$raw"

    if ! count=$(replace_ipset_from_file TSPUIPS hash:net 2000000 "$sanitized"); then
        rm -f "$sanitized"
        return 1
    fi

    rm -f "$sanitized"
    printf '%s\n' "$count" > "$STATE_DIR/tspu_count.txt"
    log_update "TSPUBLOCK updated: $count entries"
    printf '%s\n' "$count"
    return 0
}

update_govips_list() {
    local raw sanitized count
    raw=$(mktemp)
    sanitized=$(mktemp)

    if ! fetch_url "https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists_iptables/blacklist-v4.ipset" "$raw"; then
        rm -f "$raw" "$sanitized"
        return 1
    fi

    if ! sanitize_gov_file "$raw" "$sanitized"; then
        rm -f "$raw" "$sanitized"
        return 1
    fi

    rm -f "$raw"

    if ! count=$(replace_ipset_from_file GOVIPS hash:net 2000000 "$sanitized"); then
        rm -f "$sanitized"
        return 1
    fi

    rm -f "$sanitized"
    printf '%s\n' "$count" > "$STATE_DIR/gov_count.txt"
    log_update "GOVIPS updated: $count entries"
    printf '%s\n' "$count"
    return 0
}

_update_lists_parallel() {
    ensure_dirs
    ensure_ipset_exists TSPUIPS hash:net 2000000
    ensure_ipset_exists GOVIPS hash:net 2000000

    local tspu_out gov_out rc=0 tspu_count gov_count
    tspu_out=$(mktemp)
    gov_out=$(mktemp)

    (update_tspublock_list > "$tspu_out") &
    local pid1=$!
    (update_govips_list > "$gov_out") &
    local pid2=$!

    if ! wait "$pid1"; then
        warn "Ошибка обновления TSPUBLOCK"
        log_update "ERROR updating TSPUBLOCK"
        rc=1
    fi
    if ! wait "$pid2"; then
        warn "Ошибка обновления GOVIPS"
        log_update "ERROR updating GOVIPS"
        rc=1
    fi

    tspu_count=$(cat "$tspu_out" 2>/dev/null | tail -n1 || echo 0)
    gov_count=$(cat "$gov_out" 2>/dev/null | tail -n1 || echo 0)
    rm -f "$tspu_out" "$gov_out"

    if (( rc == 0 )); then
        success "TSPUBLOCK: $tspu_count, GOVIPS: $gov_count"
    fi
    return $rc
}

with_lock() {
    local lock_file=$1
    shift
    ensure_dirs
    (
        flock -w 60 9 || { echo "lock-timeout"; exit 99; }
        "$@"
    ) 9>"$lock_file"
}

_apply_all() {
    restore_ipset_state
    setup_tspublock_rules
    setup_govips_rules
    "$GEOIP_APPLY_SCRIPT" apply >/dev/null
    save_ipset_state
    log_action "Full apply completed"
}

apply_all() {
    with_lock "$UPDATE_LOCK_FILE" _apply_all
}

_update_all() {
    local rc=0
    log_update "=== update started ==="
    if ! _update_lists_parallel; then
        rc=1
    fi
    setup_tspublock_rules
    setup_govips_rules
    "$GEOIP_APPLY_SCRIPT" apply >/dev/null
    save_ipset_state
    log_update "=== update completed ==="
    return $rc
}

update_all() {
    with_lock "$UPDATE_LOCK_FILE" _update_all
}

write_systemd_units() {
    cat > "$BOOT_SERVICE" <<EOF
[Unit]
Description=RKN Watcher boot restore
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$MAIN_SCRIPT apply --quiet

[Install]
WantedBy=multi-user.target
EOF

    cat > "$UPDATE_SERVICE" <<EOF
[Unit]
Description=RKN Watcher scheduled update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$MAIN_SCRIPT update --quiet
EOF

    cat > "$UPDATE_TIMER" <<'EOF'
[Unit]
Description=RKN Watcher daily update timer

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=rkn-watcher-update.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable rkn-watcher-boot.service >/dev/null 2>&1 || true
}

enable_or_disable_timer() {
    local auto
    auto=$(get_setting AUTO_UPDATE y)
    if [[ "$auto" == "y" ]]; then
        systemctl enable --now rkn-watcher-update.timer >/dev/null 2>&1 || true
    else
        systemctl disable --now rkn-watcher-update.timer >/dev/null 2>&1 || true
    fi
}

create_launcher() {
    ln -sf "$MAIN_SCRIPT" "$BIN_PATH"
    chmod +x "$MAIN_SCRIPT"
}

copy_self_to_install_dir() {
    local source
    source=$(readlink -f "$0")
    if [[ "$source" != "$MAIN_SCRIPT" ]]; then
        cp "$source" "$MAIN_SCRIPT"
    fi
    chmod +x "$MAIN_SCRIPT"
}

install_or_upgrade() {
    check_root
    local had_existing_config="n"
    [[ -f "$SETTINGS_FILE" || -f "$WHITELIST_FILE" || -f "$BLACKLIST_FILE" ]] && had_existing_config="y"

    require_commands apt-get python3 systemctl flock
    install_dependencies
    ensure_dirs
    copy_self_to_install_dir
    write_default_settings_if_missing
    write_default_json_if_missing
    copy_helper_scripts
    normalize_existing_json_files
    create_launcher
    write_systemd_units
    enable_or_disable_timer

    ensure_ipset_exists TSPUIPS hash:net 2000000
    ensure_ipset_exists GOVIPS hash:net 2000000

    local filter_ports log_rst auto_update enable_geo enable_tspu enable_gov use_existing
    use_existing="n"
    if [[ "$had_existing_config" == "y" ]]; then
        read -r -p "Сохранить текущие настройки, если они уже есть? (y/n): " use_existing || true
        use_existing=$(normalize_yesno "$use_existing")
    fi

    if [[ "$use_existing" != "y" ]]; then
        echo
        echo "Настройка области применения GeoIP:"
        echo "1) Все порты"
        echo "2) Один порт"
        echo "3) Несколько портов"
        read -r -p "Выберите вариант (1-3): " choice
        case "$choice" in
            2)
                read -r -p "Введите порт: " filter_ports
                validate_ports_csv "$filter_ports" || { error "Некорректный порт"; exit 1; }
                filter_ports=$(normalize_ports_csv "$filter_ports")
                ;;
            3)
                read -r -p "Введите порты через запятую: " filter_ports
                validate_ports_csv "$filter_ports" || { error "Некорректный список портов"; exit 1; }
                filter_ports=$(normalize_ports_csv "$filter_ports")
                ;;
            *)
                filter_ports="all"
                ;;
        esac

        read -r -p "Включить логирование RST-пакетов? (y/n): " log_rst
        read -r -p "Включить автообновление через systemd timer? (y/n): " auto_update
        read -r -p "Включить TSPUBLOCK? (y/n): " enable_tspu
        read -r -p "Включить GOVIPS? (y/n): " enable_gov
        read -r -p "Включить GeoIP сразу? (y/n): " enable_geo

        set_setting FILTER_PORTS "$filter_ports"
        set_setting LOG_RST "$(normalize_yesno "$log_rst")"
        set_setting AUTO_UPDATE "$(normalize_yesno "$auto_update")"
        set_setting ENABLE_TSPUBLOCK "$(normalize_yesno "$enable_tspu")"
        set_setting ENABLE_GOVIPS "$(normalize_yesno "$enable_gov")"
        "$CONFIG_TOOL" set-enabled "$( [[ $(normalize_yesno "$enable_geo") == y ]] && echo true || echo false )" >/dev/null
    fi

    enable_or_disable_timer

    info "Загрузка блок-листов..."
    if ! update_all; then
        warn "Часть списков не обновилась. Существующие данные сохранены."
        apply_all || true
    fi

    systemctl enable rkn-watcher-boot.service >/dev/null 2>&1 || true
    success "Установка/обновление завершены"
}

remove_managed_firewall() {
    remove_rule_all INPUT -j TSPUBLOCK
    remove_rule_all INPUT -j GOVBLOCK
    remove_rule_all INPUT -m comment --comment rkn-watcher-geoip-hook -j RKN_GEOIP_HOOK

    for chain in TSPUBLOCK GOVBLOCK GEOIP_DROP RKN_GEOIP_HOOK; do
        iptables -F "$chain" >/dev/null 2>&1 || true
        iptables -X "$chain" >/dev/null 2>&1 || true
    done

    local set_name
    for set_name in "${MANAGED_IPSETS[@]}"; do
        ipset destroy "$set_name" >/dev/null 2>&1 || true
    done
}

uninstall_all() {
    check_root

    local confirm=""
    if [[ "${RKN_ASSUME_YES:-0}" == "1" ]]; then
        confirm="YES"
    else
        read -r -p "Для полного удаления введите YES: " confirm
    fi

    if [[ "$confirm" != "YES" ]]; then
        warn "Удаление отменено"
        return 0
    fi

    systemctl disable --now rkn-watcher-update.timer >/dev/null 2>&1 || true
    systemctl disable --now rkn-watcher-boot.service >/dev/null 2>&1 || true
    rm -f "$BOOT_SERVICE" "$UPDATE_SERVICE" "$UPDATE_TIMER"
    systemctl daemon-reload >/dev/null 2>&1 || true

    remove_managed_firewall

    rm -f "$BIN_PATH"
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    success "RKN Watcher удалён"
}

show_status() {
    local mode=${1:-interactive}
    local auto_update log_rst filter_ports tspu gov geo_enabled
    auto_update=$(get_setting AUTO_UPDATE y)
    log_rst=$(get_setting LOG_RST n)
    filter_ports=$(get_setting FILTER_PORTS all)
    tspu=$(get_setting ENABLE_TSPUBLOCK y)
    gov=$(get_setting ENABLE_GOVIPS y)
    geo_enabled=$({ "$CONFIG_TOOL" get-enabled 2>/dev/null || echo false; } | tail -n1)

    if [[ "$mode" == "interactive" ]]; then
        clear || true
        title
        echo -e "${CYAN}${APP_NAME} ${VERSION} — статус${NC}"
        title
        echo
    fi

    echo "TSPUBLOCK enabled : $tspu"
    echo "GOVIPS enabled    : $gov"
    echo "GeoIP enabled     : $geo_enabled"
    echo "Filter ports      : $filter_ports"
    echo "RST logging       : $log_rst"
    echo "Auto update       : $auto_update"
    echo
    echo "TSPUIPS entries   : $(ipset_count TSPUIPS)"
    echo "GOVIPS entries    : $(ipset_count GOVIPS)"
    echo "GeoIP allow IPs   : $(ipset_count GEOIP_ALLOW_IPS)"
    echo "GeoIP deny IPs    : $(ipset_count GEOIP_DENY_IPS)"
    echo "GeoIP countries   : $(ipset_count GEOIP_COUNTRIES_ALLOW)"
    echo
    systemctl is-enabled rkn-watcher-update.timer >/dev/null 2>&1 && echo "Timer: enabled" || echo "Timer: disabled"
    systemctl is-active rkn-watcher-update.timer >/dev/null 2>&1 && echo "Timer state: active" || true
    echo

    if [[ "$mode" == "interactive" ]]; then
        read -r -p "Нажмите Enter для продолжения..." _
    fi
}

show_rules() {
    clear || true
    title
    echo -e "${CYAN}iptables / ipset${NC}"
    title
    echo
    iptables -L INPUT -v -n | sed -n '1,40p' || true
    echo
    for chain in TSPUBLOCK GOVBLOCK RKN_GEOIP_HOOK GEOIP_DROP; do
        echo "=== $chain ==="
        iptables -L "$chain" -v -n 2>/dev/null || echo "chain absent"
        echo
    done
    for set_name in TSPUIPS GOVIPS GEOIP_ALLOW_IPS GEOIP_DENY_IPS GEOIP_COUNTRIES_ALLOW; do
        echo "=== $set_name ==="
        ipset list "$set_name" 2>/dev/null | sed -n '1,20p' || echo "set absent"
        echo
    done
    read -r -p "Нажмите Enter для продолжения..." _
}

show_logs() {
    while true; do
        clear || true
        title
        echo -e "${CYAN}Логи${NC}"
        title
        echo
        echo "1) update.log"
        echo "2) actions.log"
        echo "3) geoip.log"
        echo "4) Очистить все логи"
        echo "0) Назад"
        echo
        read -r -p "Выберите пункт: " choice
        case "$choice" in
            1) clear || true; tail -n 100 "$UPDATE_LOG" 2>/dev/null || echo "Файл пуст или отсутствует"; echo; read -r -p "Enter..." _ ;;
            2) clear || true; tail -n 100 "$ACTION_LOG" 2>/dev/null || echo "Файл пуст или отсутствует"; echo; read -r -p "Enter..." _ ;;
            3) clear || true; tail -n 100 "$GEOIP_LOG" 2>/dev/null || echo "Файл пуст или отсутствует"; echo; read -r -p "Enter..." _ ;;
            4)
                : > "$UPDATE_LOG"
                : > "$ACTION_LOG"
                : > "$GEOIP_LOG"
                success "Логи очищены"
                sleep 1
                ;;
            0) break ;;
            *) warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

show_geoip_config() {
    clear || true
    title
    echo -e "${CYAN}Конфигурация GeoIP${NC}"
    title
    echo
    echo "--- whitelist.json ---"
    "$CONFIG_TOOL" show whitelist || true
    echo
    echo "--- blacklist.json ---"
    "$CONFIG_TOOL" show blacklist || true
    echo
    read -r -p "Нажмите Enter для продолжения..." _
}

reapply_rules() {
    if apply_all; then
        success "Правила успешно применены"
    else
        error "Не удалось применить правила"
    fi
    sleep 1
}

set_filter_ports_interactive() {
    local value
    read -r -p "Введите all или список портов через запятую: " value
    validate_ports_csv "$value" || { error "Некорректное значение"; sleep 1; return 1; }
    value=$(normalize_ports_csv "$value")
    set_setting FILTER_PORTS "$value"
    apply_all
    success "FILTER_PORTS обновлён: $value"
    sleep 1
}

toggle_setting_yesno() {
    local key=$1
    local current next
    current=$(get_setting "$key" n)
    if [[ "$current" == "y" ]]; then
        next="n"
    else
        next="y"
    fi
    set_setting "$key" "$next"
    printf '%s\n' "$next"
}

toggle_tspublock() {
    local next
    next=$(toggle_setting_yesno ENABLE_TSPUBLOCK)
    apply_all
    success "TSPUBLOCK: $next"
    sleep 1
}

toggle_govips() {
    local next
    next=$(toggle_setting_yesno ENABLE_GOVIPS)
    apply_all
    success "GOVIPS: $next"
    sleep 1
}

toggle_rst_logging() {
    local next
    next=$(toggle_setting_yesno LOG_RST)
    apply_all
    success "LOG_RST: $next"
    sleep 1
}

toggle_auto_update() {
    local next
    next=$(toggle_setting_yesno AUTO_UPDATE)
    enable_or_disable_timer
    success "AUTO_UPDATE: $next"
    sleep 1
}

toggle_geoip_enabled() {
    local current next_bool msg
    current=$({ "$CONFIG_TOOL" get-enabled 2>/dev/null || echo false; } | tail -n1)
    if [[ "$current" == "true" ]]; then
        next_bool="false"
        msg="отключён"
    else
        next_bool="true"
        msg="включён"
    fi
    "$CONFIG_TOOL" set-enabled "$next_bool" >/dev/null
    apply_all
    success "GeoIP $msg"
    sleep 1
}

run_config_tool_and_apply() {
    local output
    if ! output=$("$CONFIG_TOOL" "$@" 2>&1); then
        error "$output"
        sleep 1
        return 1
    fi
    apply_all
    success "$output"
    sleep 1
}

geoip_menu() {
    while true; do
        clear || true
        title
        echo -e "${CYAN}Настройка GeoIP${NC}"
        title
        echo
        echo "1) Вкл/выкл GeoIP"
        echo "2) Добавить страну"
        echo "3) Удалить страну"
        echo "4) Добавить allow IP/CIDR"
        echo "5) Удалить allow IP/CIDR"
        echo "6) Добавить allow порт"
        echo "7) Удалить allow порт"
        echo "8) Добавить deny IP/CIDR"
        echo "9) Удалить deny IP/CIDR"
        echo "10) Добавить deny порт"
        echo "11) Удалить deny порт"
        echo "12) Показать конфиг"
        echo "0) Назад"
        echo
        read -r -p "Выберите пункт: " choice
        case "$choice" in
            1) toggle_geoip_enabled ;;
            2)
                read -r -p "Код страны (например, FI): " value
                validate_country_code "$value" || { error "Некорректный код"; sleep 1; continue; }
                run_config_tool_and_apply add-country "$value"
                ;;
            3)
                read -r -p "Код страны: " value
                validate_country_code "$value" || { error "Некорректный код"; sleep 1; continue; }
                run_config_tool_and_apply remove-country "$value"
                ;;
            4)
                read -r -p "IP или CIDR: " value
                validate_ip_or_cidr "$value" || { error "Некорректный IP/CIDR"; sleep 1; continue; }
                run_config_tool_and_apply add-ip "$value"
                ;;
            5)
                read -r -p "IP или CIDR: " value
                validate_ip_or_cidr "$value" || { error "Некорректный IP/CIDR"; sleep 1; continue; }
                run_config_tool_and_apply remove-ip "$value"
                ;;
            6)
                read -r -p "Порт: " value
                validate_single_port "$value" || { error "Некорректный порт"; sleep 1; continue; }
                run_config_tool_and_apply add-port "$value"
                ;;
            7)
                read -r -p "Порт: " value
                validate_single_port "$value" || { error "Некорректный порт"; sleep 1; continue; }
                run_config_tool_and_apply remove-port "$value"
                ;;
            8)
                read -r -p "IP или CIDR: " value
                validate_ip_or_cidr "$value" || { error "Некорректный IP/CIDR"; sleep 1; continue; }
                run_config_tool_and_apply add-deny-ip "$value"
                ;;
            9)
                read -r -p "IP или CIDR: " value
                validate_ip_or_cidr "$value" || { error "Некорректный IP/CIDR"; sleep 1; continue; }
                run_config_tool_and_apply remove-deny-ip "$value"
                ;;
            10)
                read -r -p "Порт: " value
                validate_single_port "$value" || { error "Некорректный порт"; sleep 1; continue; }
                run_config_tool_and_apply add-deny-port "$value"
                ;;
            11)
                read -r -p "Порт: " value
                validate_single_port "$value" || { error "Некорректный порт"; sleep 1; continue; }
                run_config_tool_and_apply remove-deny-port "$value"
                ;;
            12) show_geoip_config ;;
            0) break ;;
            *) warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

settings_menu() {
    while true; do
        clear || true
        title
        echo -e "${CYAN}Настройки${NC}"
        title
        echo
        echo "1) Изменить FILTER_PORTS"
        echo "2) Вкл/выкл LOG_RST"
        echo "3) Вкл/выкл AUTO_UPDATE"
        echo "4) Пере-применить правила"
        echo "0) Назад"
        echo
        read -r -p "Выберите пункт: " choice
        case "$choice" in
            1) set_filter_ports_interactive ;;
            2) toggle_rst_logging ;;
            3) toggle_auto_update ;;
            4) reapply_rules ;;
            0) break ;;
            *) warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

blocklists_menu() {
    while true; do
        clear || true
        title
        echo -e "${CYAN}Блок-листы${NC}"
        title
        echo
        echo "1) Вкл/выкл TSPUBLOCK"
        echo "2) Вкл/выкл GOVIPS"
        echo "3) Обновить оба списка"
        echo "4) Показать правила / ipset"
        echo "0) Назад"
        echo
        read -r -p "Выберите пункт: " choice
        case "$choice" in
            1) toggle_tspublock ;;
            2) toggle_govips ;;
            3)
                if update_all; then success "Обновление завершено"; else warn "Обновление завершено с ошибками"; fi
                sleep 1
                ;;
            4) show_rules ;;
            0) break ;;
            *) warn "Неверный выбор"; sleep 1 ;;
        esac
    done
}

main_menu() {
    while true; do
        clear || true
        title
        echo -e "${CYAN}${APP_NAME} ${VERSION}${NC}"
        title
        echo
        if is_installed; then
            echo "1) Блок-листы"
            echo "2) GeoIP"
            echo "3) Настройки"
            echo "4) Статус"
            echo "5) Логи"
            echo "6) Переустановить / обновить"
            echo "7) Удалить"
            echo "0) Выход"
        else
            echo "1) Установить"
            echo "0) Выход"
        fi
        echo
        read -r -p "Выберите пункт: " choice
        if is_installed; then
            case "$choice" in
                1) blocklists_menu ;;
                2) geoip_menu ;;
                3) settings_menu ;;
                4) show_status ;;
                5) show_logs ;;
                6) install_or_upgrade ;;
                7) uninstall_all ;;
                0) exit 0 ;;
                *) warn "Неверный выбор"; sleep 1 ;;
            esac
        else
            case "$choice" in
                1) install_or_upgrade ;;
                0) exit 0 ;;
                *) warn "Неверный выбор"; sleep 1 ;;
            esac
        fi
    done
}

print_usage() {
    cat <<EOF
Usage: $0 [command] [--quiet]

Commands:
  install      install or upgrade
  update       refresh TSPUBLOCK and GOVIPS
  apply        re-apply firewall rules from current config
  status       print status
  uninstall    remove application
  menu         interactive menu (default)
EOF
}

main() {
    check_root

    local cmd=${1:-menu}
    local quiet="n"
    local arg
    for arg in "$@"; do
        [[ "$arg" == "--quiet" ]] && quiet="y"
    done

    case "$cmd" in
        install)
            install_or_upgrade
            ;;
        update)
            if update_all; then
                [[ "$quiet" == "y" ]] || success "Update completed"
            else
                [[ "$quiet" == "y" ]] || warn "Update completed with errors"
                return 1
            fi
            ;;
        apply)
            if apply_all; then
                [[ "$quiet" == "y" ]] || success "Apply completed"
            else
                [[ "$quiet" == "y" ]] || warn "Apply failed"
                return 1
            fi
            ;;
        status)
            show_status noninteractive
            ;;
        uninstall)
            uninstall_all
            ;;
        menu)
            main_menu
            ;;
        -h|--help|help)
            print_usage
            ;;
        *)
            error "Неизвестная команда: $cmd"
            print_usage
            return 1
            ;;
    esac
}

main "$@"
