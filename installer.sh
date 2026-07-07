#!/usr/bin/env bash
set -euo pipefail

APP_NAME="RKN Watcher Installer"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_SCRIPT="$SCRIPT_DIR/rkn-watcher.sh"
INSTALLED_APP_SCRIPT="/opt/rkn-watcher/rkn-watcher.sh"
BIN_PATH="/usr/local/bin/rkn-watcher"

STATE_DIR="/var/lib/rkn-watcher/state"
PKG_MANIFEST="$STATE_DIR/installer-packages.txt"

REQUIRED_PACKAGES=(iptables ipset curl ca-certificates python3 util-linux)
MANAGED_IPSETS=(TSPUIPS GOVIPS GEOIP_ALLOW_IPS GEOIP_DENY_IPS GEOIP_COUNTRIES_ALLOW)
MANAGED_CHAINS=(TSPUBLOCK GOVBLOCK GEOIP_DROP RKN_GEOIP_HOOK)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR]${NC} $*"; }
title() { echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"; }

check_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "Установщик должен быть запущен от root"
        echo "Пример: sudo ./installer.sh"
        exit 1
    fi
}

check_platform() {
    command -v apt-get >/dev/null 2>&1 || { error "Поддерживаются только Debian/Ubuntu (не найден apt-get)"; exit 1; }
    command -v dpkg-query >/dev/null 2>&1 || { error "Не найден dpkg-query"; exit 1; }
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

collect_missing_packages() {
    local missing=()
    local pkg
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! package_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done
    printf '%s\n' "${missing[@]:-}"
}

save_installed_packages_manifest() {
    local new_packages=("$@")
    mkdir -p "$(dirname "$PKG_MANIFEST")"

    python3 - "$PKG_MANIFEST" "${new_packages[@]}" <<'PY'
import os
import sys

path = sys.argv[1]
items = [x for x in sys.argv[2:] if x.strip()]
current = []
if os.path.exists(path):
    with open(path, 'r', encoding='utf-8') as fh:
        current = [line.strip() for line in fh if line.strip()]
merged = sorted(set(current + items))
with open(path, 'w', encoding='utf-8') as fh:
    for item in merged:
        fh.write(item + '\n')
PY
}

show_dependency_status() {
    title
    echo -e "${CYAN}Зависимости${NC}"
    title
    local pkg
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if package_installed "$pkg"; then
            echo -e "$pkg : ${GREEN}installed${NC}"
        else
            echo -e "$pkg : ${YELLOW}missing${NC}"
        fi
    done
    echo
}

install_dependencies_interactive() {
    mapfile -t missing < <(collect_missing_packages)
    if [[ ${#missing[@]} -eq 0 || ( ${#missing[@]} -eq 1 && -z ${missing[0]} ) ]]; then
        success "Все необходимые зависимости уже установлены"
        return 0
    fi

    info "Будут установлены зависимости: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "${missing[@]}"
    save_installed_packages_manifest "${missing[@]}"
    success "Зависимости установлены"
}

run_install() {
    [[ -f "$APP_SCRIPT" ]] || { error "Не найден файл $APP_SCRIPT"; exit 1; }

    show_dependency_status
    install_dependencies_interactive

    info "Запуск основного интерактивного установщика RKN Watcher..."
    RKN_SKIP_DEP_INSTALL=1 "$APP_SCRIPT" install
}

remove_rule_all() {
    local chain=$1
    shift
    while iptables -C "$chain" "$@" >/dev/null 2>&1; do
        iptables -D "$chain" "$@" >/dev/null 2>&1 || break
    done
}

manual_cleanup() {
    info "Выполняю аварийную очистку управляемых изменений..."

    remove_rule_all INPUT -j TSPUBLOCK || true
    remove_rule_all INPUT -j GOVBLOCK || true
    remove_rule_all INPUT -m comment --comment rkn-watcher-geoip-hook -j RKN_GEOIP_HOOK || true

    local chain
    for chain in "${MANAGED_CHAINS[@]}"; do
        iptables -F "$chain" >/dev/null 2>&1 || true
        iptables -X "$chain" >/dev/null 2>&1 || true
    done

    local set_name
    for set_name in "${MANAGED_IPSETS[@]}"; do
        ipset destroy "$set_name" >/dev/null 2>&1 || true
    done

    systemctl disable --now rkn-watcher-update.timer >/dev/null 2>&1 || true
    systemctl disable --now rkn-watcher-boot.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/rkn-watcher-update.timer
    rm -f /etc/systemd/system/rkn-watcher-update.service
    rm -f /etc/systemd/system/rkn-watcher-boot.service
    systemctl daemon-reload >/dev/null 2>&1 || true

    rm -f "$BIN_PATH"
    rm -rf /opt/rkn-watcher /etc/rkn-watcher /var/lib/rkn-watcher /var/log/rkn-watcher

    success "Аварийная очистка завершена"
}

read_manifest_packages() {
    local path="$PKG_MANIFEST"
    [[ -f "$path" ]] || return 0
    awk 'NF {print $0}' "$path"
}

remove_installer_packages() {
    local packages=("$@")
    local installed=()
    local pkg

    for pkg in "${packages[@]}"; do
        [[ -z "$pkg" ]] && continue
        if package_installed "$pkg"; then
            installed+=("$pkg")
        fi
    done

    if [[ ${#installed[@]} -eq 0 ]]; then
        info "Нет пакетов, которые были бы установлены именно этим установщиком и ещё присутствовали в системе"
        return 0
    fi

    echo
    warn "Дополнительно можно удалить пакеты, которые этот установщик доустановил ранее: ${installed[*]}"
    read -r -p "Удалить эти пакеты тоже? (y/n): " answer
    case "${answer:-n}" in
        y|Y|yes|YES)
            export DEBIAN_FRONTEND=noninteractive
            apt-get remove -y "${installed[@]}" || true
            apt-get autoremove -y || true
            success "Пакеты удалены"
            ;;
        *)
            info "Удаление пакетов пропущено"
            ;;
    esac
}

run_uninstall() {
    local runner=""
    local packages=()

    mapfile -t packages < <(read_manifest_packages)

    if [[ -x "$INSTALLED_APP_SCRIPT" ]]; then
        runner="$INSTALLED_APP_SCRIPT"
    elif [[ -x "$BIN_PATH" ]]; then
        runner="$BIN_PATH"
    elif [[ -x "$APP_SCRIPT" ]]; then
        runner="$APP_SCRIPT"
    fi

    echo
    warn "Будут удалены все изменения, внесённые RKN Watcher:"
    echo "- systemd timer и service"
    echo "- правила iptables и управляемые ipset"
    echo "- конфигурация, state, кэш, логи"
    echo "- файлы в /opt/rkn-watcher и ссылка /usr/local/bin/rkn-watcher"
    echo
    read -r -p "Продолжить полное удаление? (напишите YES): " confirm
    [[ "$confirm" == "YES" ]] || { warn "Удаление отменено"; return 0; }

    if [[ -n "$runner" ]]; then
        RKN_ASSUME_YES=1 "$runner" uninstall || manual_cleanup
    else
        manual_cleanup
    fi

    remove_installer_packages "${packages[@]}"
}

show_status() {
    title
    echo -e "${CYAN}${APP_NAME}${NC}"
    title
    echo
    if [[ -x "$INSTALLED_APP_SCRIPT" || -x "$BIN_PATH" ]]; then
        echo "Основной скрипт: установлен"
    else
        echo "Основной скрипт: не установлен"
    fi
    echo
    show_dependency_status
}

main_menu() {
    while true; do
        clear || true
        title
        echo -e "${CYAN}${APP_NAME}${NC}"
        title
        echo
        echo "1) Установить / обновить RKN Watcher"
        echo "2) Проверить зависимости"
        echo "3) Полное удаление всех внесённых изменений"
        echo "4) Показать статус"
        echo "0) Выход"
        echo
        read -r -p "Выберите пункт: " choice
        case "$choice" in
            1)
                run_install
                read -r -p "Нажмите Enter для продолжения..." _
                ;;
            2)
                show_dependency_status
                read -r -p "Нажмите Enter для продолжения..." _
                ;;
            3)
                run_uninstall
                read -r -p "Нажмите Enter для продолжения..." _
                ;;
            4)
                show_status
                read -r -p "Нажмите Enter для продолжения..." _
                ;;
            0)
                exit 0
                ;;
            *)
                warn "Неверный выбор"
                sleep 1
                ;;
        esac
    done
}

print_usage() {
    cat <<EOF
Usage: $0 [command]

Commands:
  install      проверить/установить зависимости и запустить установку RKN Watcher
  uninstall    полное удаление внесённых изменений
  deps         показать статус зависимостей
  status       показать статус установщика и программы
  menu         интерактивное меню (по умолчанию)
EOF
}

main() {
    check_root
    check_platform

    local cmd=${1:-menu}
    case "$cmd" in
        install)
            run_install
            ;;
        uninstall)
            run_uninstall
            ;;
        deps)
            show_dependency_status
            ;;
        status)
            show_status
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
            exit 1
            ;;
    esac
}

main "$@"
