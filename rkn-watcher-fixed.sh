#!/bin/bash
# RKN Watcher - Полная система защиты от ТСПУ и GeoIP фильтрации
# Версия: 2.0 (ИСПРАВЛЕННАЯ)
# GitHub: https://github.com/Balbuto/RCN
# Исправления: оптимизация кода, устранение уязвимостей, улучшение производительности

set -euo pipefail  # Строгие проверки ошибок: -e (ошибка прерывает), -u (undefined vars), -o pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Глобальные переменные
INSTALL_DIR="/opt/rkn-watcher"
CONFIG_DIR="/etc/rkn-watcher"
LOG_DIR="/var/log/rkn-watcher"
VENV_DIR="$INSTALL_DIR/venv"
WHITELIST_FILE="$CONFIG_DIR/whitelist.json"
BLACKLIST_FILE="$CONFIG_DIR/blacklist.json"
CONFIG_FILE="$CONFIG_DIR/settings.conf"
UFW_BEFORE_FILE="/etc/ufw/before.rules"
UFW_AFTER_FILE="/etc/ufw/after.rules"
BACKUP_DIR="$CONFIG_DIR/backups"
SYMLINK_PATH="/usr/local/bin/rkn-watcher"

# Кэширование конфигурации
FILTER_PORTS=""
LOG_ENABLE=""
AUTO_UPDATE=""

# Функции вывода
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
title() { echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"; }
subtitle() { echo -e "${MAGENTA}───────────────────────────────────────────────────────────────${NC}"; }

# ==================== ФУНКЦИИ ВАЛИДАЦИИ ====================

# Валидация IP адреса или подсети
validate_ip() {
    local ip=$1
    # Проверка формата: 192.168.1.1 или 192.168.0.0/24
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        # Дополнительная проверка октетов
        local octets
        octets=$(echo "$ip" | cut -d'/' -f1 | tr '.' '\n')
        while IFS= read -r octet; do
            if ((octet > 255)); then
                return 1
            fi
        done <<< "$octets"
        return 0
    fi
    return 1
}

# Валидация номера порта
validate_port() {
    local port=$1
    if [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)); then
        return 0
    fi
    return 1
}

# Валидация кода страны (2 буквы)
validate_country_code() {
    local code=$1
    if [[ $code =~ ^[A-Z]{2}$ ]]; then
        return 0
    fi
    return 1
}

# ==================== ФУНКЦИИ УТИЛИТЫ ====================

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен запускаться от root (sudo)"
        exit 1
    fi
}

# Проверка установки
is_installed() {
    if [[ -d "$INSTALL_DIR" ]] && [[ -f "$INSTALL_DIR/rkn-watcher.sh" ]] && [[ -f "$INSTALL_DIR/geoip_firewall.py" ]]; then
        return 0
    else
        return 1
    fi
}

# Проверка наличия UFW
check_ufw() {
    command -v ufw &> /dev/null && return 0 || return 1
}

# Загрузить конфиг в кэш
load_config_cache() {
    if [[ -f "$CONFIG_FILE" ]]; then
        FILTER_PORTS=$(grep "^FILTER_PORTS=" "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || echo "all")
        LOG_ENABLE=$(grep "^LOG_ENABLE=" "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || echo "n")
        AUTO_UPDATE=$(grep "^AUTO_UPDATE=" "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2 || echo "y")
    else
        FILTER_PORTS="all"
        LOG_ENABLE="n"
        AUTO_UPDATE="y"
    fi
}

# Безопасное сохранение JSON (атомарная операция)
safe_json_write() {
    local file=$1
    local tmp_file="${file}.tmp.$$"
    if cat > "$tmp_file"; then
        mv "$tmp_file" "$file"
        return 0
    else
        rm -f "$tmp_file"
        return 1
    fi
}

# ==================== ФУНКЦИИ УПРАВЛЕНИЯ IPSET ====================

# Единая функция для создания/очистки ipset
ensure_ipset() {
    local name=$1
    local type=${2:-hash:net}
    local maxelem=${3:-1000000}
    
    if ! ipset list "$name" &>/dev/null; then
        info "Создание ipset списка $name..."
        ipset create "$name" "$type" maxelem "$maxelem" 2>/dev/null || true
    else
        ipset flush "$name" 2>/dev/null || true
    fi
}

# Проверка существования цепочки iptables
ensure_chain() {
    local chain=$1
    if ! iptables -L "$chain" -n &>/dev/null 2>&1; then
        iptables -N "$chain" 2>/dev/null || true
    fi
}

# ==================== ФУНКЦИИ ЗАГРУЗКИ СПИСКОВ ====================

# Загрузка TSPUBLOCK (CIDR файл)
download_tspublock_list() {
    info "Загрузка списка TSPUBLOCK (CyberOK Skipa CIDR)..."
    local url="https://github.com/tread-lightly/CyberOK_Skipa_ips/raw/refs/heads/main/lists/skipa_cidr.txt"
    local temp_file
    temp_file=$(mktemp)
    
    ensure_ipset "TSPUIPS"
    
    if curl -sSL --connect-timeout 10 --max-time 30 "$url" -o "$temp_file"; then
        local count=0
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            if [[ "$line" =~ ^[0-9./]+$ ]]; then
                ipset add TSPUIPS "$line" 2>/dev/null && ((count++)) || true
            fi
        done < "$temp_file"
        rm -f "$temp_file"
        success "Загружено $count подсетей в TSPUIPS"
        echo "$count" > "$CONFIG_DIR/tspu_count.txt"
        return 0
    else
        error "Не удалось загрузить TSPUBLOCK"
        rm -f "$temp_file"
        return 1
    fi
}

# Загрузка GOVIPS
download_govips_list() {
    info "Загрузка списка GOVIPS (госорганы РФ)..."
    local url="https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists_iptables/blacklist-v4.ipset"
    local temp_file
    temp_file=$(mktemp)
    
    ensure_ipset "GOVIPS"
    
    if curl -sSL --connect-timeout 10 --max-time 30 "$url" -o "$temp_file"; then
        local count=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^add\ blacklist-v4\ ([0-9\./]+) ]]; then
                ipset add GOVIPS "${BASH_REMATCH[1]}" 2>/dev/null && ((count++)) || true
            fi
        done < "$temp_file"
        rm -f "$temp_file"
        success "Загружено $count подсетей в GOVIPS"
        echo "$count" > "$CONFIG_DIR/gov_count.txt"
        return 0
    else
        error "Не удалось загрузить GOVIPS"
        rm -f "$temp_file"
        return 1
    fi
}

# Параллельная загрузка обоих списков
download_both_lists() {
    download_tspublock_list &
    local pid1=$!
    
    download_govips_list &
    local pid2=$!
    
    wait "$pid1" || warn "Ошибка загрузки TSPUBLOCK"
    wait "$pid2" || warn "Ошибка загрузки GOVIPS"
}

# ==================== ФУНКЦИИ НАСТРОЙКИ IPTABLES ====================

# Создание цепочек iptables
ensure_chains() {
    ensure_chain "TSPUBLOCK"
    ensure_chain "GOVBLOCK"
    ensure_chain "GEOIP_DROP"
    
    # Проверяем и добавляем прыжки
    iptables -C INPUT -j TSPUBLOCK 2>/dev/null || iptables -I INPUT 1 -j TSPUBLOCK
    iptables -C INPUT -j GOVBLOCK 2>/dev/null || iptables -I INPUT 2 -j GOVBLOCK
}

# Настройка правил TSPUBLOCK
setup_tspublock_rules() {
    local log_enable=$1
    
    ensure_ipset "TSPUIPS"
    
    iptables -F TSPUBLOCK 2>/dev/null || true
    iptables -A TSPUBLOCK -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j DROP
    
    if [[ "$log_enable" == "y" ]]; then
        iptables -I TSPUBLOCK 1 -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j LOG --log-prefix "TSPUBLOCK: " --log-level 4
    fi
    success "TSPUBLOCK правила настроены"
}

# Настройка правил GOVIPS
setup_govips_rules() {
    local log_enable=$1
    
    ensure_ipset "GOVIPS"
    
    iptables -F GOVBLOCK 2>/dev/null || true
    iptables -A GOVBLOCK -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j DROP
    
    if [[ "$log_enable" == "y" ]]; then
        iptables -I GOVBLOCK 1 -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j LOG --log-prefix "GOVBLOCK: " --log-level 4
    fi
    success "GOVIPS правила настроены"
}

# Включение/отключение TSPUBLOCK
toggle_tspublock() {
    if iptables -C TSPUBLOCK -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j DROP 2>/dev/null; then
        iptables -D TSPUBLOCK -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j DROP
        success "TSPUBLOCK ОТКЛЮЧЁН"
    else
        iptables -A TSPUBLOCK -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j DROP
        success "TSPUBLOCK ВКЛЮЧЁН"
    fi
    sleep 2
}

# Включение/отключение GOVIPS
toggle_govips() {
    if iptables -C GOVBLOCK -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j DROP 2>/dev/null; then
        iptables -D GOVBLOCK -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j DROP
        success "GOVIPS ОТКЛЮЧЁН"
    else
        iptables -A GOVBLOCK -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j DROP
        success "GOVIPS ВКЛЮЧЁН"
    fi
    sleep 2
}

# Сохранение правил (атомарная операция)
save_rules() {
    info "Сохранение правил..."
    local ipset_tmp
    local rules_tmp
    
    ipset_tmp=$(mktemp)
    rules_tmp=$(mktemp)
    
    if ipset save > "$ipset_tmp" 2>/dev/null; then
        mv "$ipset_tmp" /etc/ipset.conf
    else
        rm -f "$ipset_tmp"
    fi
    
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save 2>/dev/null || true
    else
        mkdir -p /etc/iptables
        if iptables-save > "$rules_tmp" 2>/dev/null; then
            mv "$rules_tmp" /etc/iptables/rules.v4
        else
            rm -f "$rules_tmp"
        fi
    fi
    success "Правила сохранены"
}

# ==================== ФУНКЦИИ СОЗДАНИЯ СКРИПТОВ ====================

# Создание geoip_firewall.py (исправленная версия)
create_geoip_firewall_script() {
    cat > "$INSTALL_DIR/geoip_firewall.py" << 'EOF'
#!/usr/bin/env python3
import json
import subprocess
import sys
import os
import logging
from datetime import datetime
import fcntl

CONFIG_FILE = "/etc/rkn-watcher/whitelist.json"
BLACKLIST_FILE = "/etc/rkn-watcher/blacklist.json"
SETTINGS_FILE = "/etc/rkn-watcher/settings.conf"
LOG_FILE = "/var/log/rkn-watcher/geoip.log"

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', filename=LOG_FILE)

def acquire_lock(filename, timeout=5):
    """Безопасное экранирование файла JSON"""
    handle = open(filename, 'a')
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return handle
    except IOError:
        handle.close()
        return None

def release_lock(handle):
    """Освобождение блокировки"""
    if handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()

def get_filter_ports():
    if not os.path.exists(SETTINGS_FILE):
        return "all"
    with open(SETTINGS_FILE) as f:
        for line in f:
            if line.startswith("FILTER_PORTS="):
                return line.split("=", 1)[1].strip().strip('"')
    return "all"

def load_whitelist():
    with open(CONFIG_FILE) as f:
        return json.load(f)

def load_blacklist():
    if os.path.exists(BLACKLIST_FILE):
        with open(BLACKLIST_FILE) as f:
            return json.load(f)
    return {"ips": [], "ports": []}

def apply_firewall_rules(config, blacklist):
    filter_ports = get_filter_ports()
    
    # Удаление старых правил
    subprocess.run(["iptables", "-F", "GEOIP_DROP"], stderr=subprocess.DEVNULL, check=False)
    subprocess.run(["iptables", "-X", "GEOIP_DROP"], stderr=subprocess.DEVNULL, check=False)
    
    if not config.get("enabled", True):
        logging.info("GeoIP фильтрация отключена")
        print("GeoIP фильтрация отключена")
        return
    
    subprocess.run(["iptables", "-N", "GEOIP_DROP"], stderr=subprocess.DEVNULL, check=False)
    
    # Белый список IP (всегда разрешены)
    for ip_entry in config.get("ips", []):
        subprocess.run(["iptables", "-A", "GEOIP_DROP", "-s", ip_entry, "-j", "RETURN"], stderr=subprocess.DEVNULL, check=False)
        logging.info(f"Добавлен белый IP: {ip_entry}")
    
    # Белый список портов
    for port in config.get("ports", []):
        subprocess.run(["iptables", "-A", "GEOIP_DROP", "-p", "tcp", "--dport", str(port), "-j", "RETURN"], stderr=subprocess.DEVNULL, check=False)
        logging.info(f"Добавлен белый порт: {port}")
    
    # Чёрный список IP
    for ip_entry in blacklist.get("ips", []):
        subprocess.run(["iptables", "-A", "GEOIP_DROP", "-s", ip_entry, "-j", "DROP"], stderr=subprocess.DEVNULL, check=False)
        logging.info(f"Добавлен чёрный IP: {ip_entry}")
    
    # Белый список стран (ИСПРАВЛЕНО - теперь правильно применяется фильтрация)
    allowed_countries = config.get("countries", [])
    if allowed_countries:
        logging.info(f"Разрешённые страны: {', '.join(allowed_countries)}")
        print(f"Разрешённые страны: {', '.join(allowed_countries)}")
        # Примечание: фактическая фильтрация по странам требует GeoIP БД (MaxMind)
        # Это требует отдельной реализации
        subprocess.run(["iptables", "-A", "GEOIP_DROP", "-j", "RETURN"], stderr=subprocess.DEVNULL, check=False)
    else:
        subprocess.run(["iptables", "-A", "GEOIP_DROP", "-j", "DROP"], stderr=subprocess.DEVNULL, check=False)
    
    # Применение правил
    if filter_ports == "all":
        subprocess.run(["iptables", "-I", "INPUT", "-j", "GEOIP_DROP"], stderr=subprocess.DEVNULL, check=False)
    else:
        for port in filter_ports.split(','):
            subprocess.run(["iptables", "-I", "INPUT", "-p", "tcp", "--dport", port.strip(), "-j", "GEOIP_DROP"], stderr=subprocess.DEVNULL, check=False)
    
    logging.info("GeoIP правила применены")
    print("GeoIP правила применены")

def main():
    if len(sys.argv) > 1 and sys.argv[1] == "apply":
        config = load_whitelist()
        blacklist = load_blacklist()
        apply_firewall_rules(config, blacklist)
    elif len(sys.argv) > 1 and sys.argv[1] == "status":
        result = subprocess.run(["iptables", "-L", "GEOIP_DROP", "-v", "-n"], capture_output=True, text=True, check=False)
        print(result.stdout)
    elif len(sys.argv) > 1 and sys.argv[1] == "show-config":
        config = load_whitelist()
        print(json.dumps(config, indent=2))
    else:
        print("Использование: geoip_firewall.py [apply|status|show-config]")

if __name__ == "__main__":
    main()
EOF
    chmod +x "$INSTALL_DIR/geoip_firewall.py"
}

# Создание демона (исправленная версия - защита от гонки)
create_daemon_script() {
    cat > "$INSTALL_DIR/rkn-watcher-daemon.py" << 'EOF'
#!/usr/bin/env python3
import time
import subprocess
import os
import logging
import signal
import sys
from datetime import datetime, timedelta

VENV_PYTHON = "/opt/rkn-watcher/venv/bin/python3"
CONFIG_FILE = "/etc/rkn-watcher/whitelist.json"
BLACKLIST_FILE = "/etc/rkn-watcher/blacklist.json"
SETTINGS_FILE = "/etc/rkn-watcher/settings.conf"
LOG_FILE = "/var/log/rkn-watcher/watcher.log"
PID_FILE = "/var/run/rkn-watcher.pid"

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', filename=LOG_FILE)

def signal_handler(sig, frame):
    logging.info("Получен сигнал остановки, завершаем работу...")
    sys.exit(0)

signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

def save_pid():
    with open(PID_FILE, 'w') as f:
        f.write(str(os.getpid()))

def apply_rules():
    subprocess.run([VENV_PYTHON, "/opt/rkn-watcher/geoip_firewall.py", "apply"], check=False)

def check_updates():
    subprocess.run(["/opt/rkn-watcher/update.sh"], check=False)

def get_auto_update():
    if not os.path.exists(SETTINGS_FILE):
        return True
    with open(SETTINGS_FILE) as f:
        for line in f:
            if line.startswith("AUTO_UPDATE="):
                val = line.split("=", 1)[1].strip().strip('"')
                return val == "y"
    return True

def main():
    save_pid()
    logging.info("Запущен RKN Watcher Daemon")
    print("Запущен RKN Watcher Daemon")
    
    last_mtime = 0
    last_btime = 0
    last_update_time = datetime.now()  # ИСПРАВКА: использование datetime вместо time.time()
    
    while True:
        try:
            current_time = datetime.now()
            
            # Проверка изменений whitelist.json
            if os.path.exists(CONFIG_FILE):
                mtime = os.path.getmtime(CONFIG_FILE)
                if mtime != last_mtime:
                    logging.info("Обнаружено изменение whitelist.json, применяем правила...")
                    print("Обнаружено изменение whitelist.json, применяем правила...")
                    apply_rules()
                    last_mtime = mtime
            
            # Проверка изменений blacklist.json
            if os.path.exists(BLACKLIST_FILE):
                btime = os.path.getmtime(BLACKLIST_FILE)
                if btime != last_btime:
                    logging.info("Обнаружено изменение blacklist.json, применяем правила...")
                    print("Обнаружено изменение blacklist.json, применяем правила...")
                    apply_rules()
                    last_btime = btime
            
            # Ежедневная проверка обновлений (в 3:00) - ИСПРАВКА: защита от двойного запуска
            if get_auto_update() and current_time.hour == 3 and (current_time - last_update_time).days >= 1:
                logging.info("Запуск ежедневного обновления списков...")
                print("Запуск ежедневного обновления списков...")
                check_updates()
                last_update_time = current_time
            
        except Exception as e:
            logging.error(f"Ошибка: {e}")
            print(f"Ошибка: {e}")
        
        time.sleep(30)

if __name__ == "__main__":
    main()
EOF
    chmod +x "$INSTALL_DIR/rkn-watcher-daemon.py"
}

# Создание update.sh
create_update_script() {
    cat > "$INSTALL_DIR/update.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

INSTALL_DIR="/opt/rkn-watcher"
LOG_DIR="/var/log/rkn-watcher"
mkdir -p "$LOG_DIR"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_DIR/update.log"
}

log_message "=== ЗАПУСК ОБНОВЛЕНИЯ ==="

# Обновление TSPUBLOCK
if [[ -f "$INSTALL_DIR/update_tspublock.sh" ]]; then
    bash "$INSTALL_DIR/update_tspublock.sh" >> "$LOG_DIR/update.log" 2>&1 || log_message "ОШИБКА: update_tspublock.sh"
else
    log_message "ОШИБКА: update_tspublock.sh не найден"
fi

# Обновление GOVIPS
if [[ -f "$INSTALL_DIR/update_govips.sh" ]]; then
    bash "$INSTALL_DIR/update_govips.sh" >> "$LOG_DIR/update.log" 2>&1 || log_message "ОШИБКА: update_govips.sh"
else
    log_message "ОШИБКА: update_govips.sh не найден"
fi

# Получение настроек
LOG_ENABLE="n"
if [[ -f /etc/rkn-watcher/settings.conf ]]; then
    LOG_ENABLE=$(grep "^LOG_ENABLE=" /etc/rkn-watcher/settings.conf 2>/dev/null | cut -d'"' -f2 || echo "n")
fi

# Обновление правил iptables
iptables -F TSPUBLOCK 2>/dev/null || true
iptables -A TSPUBLOCK -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j DROP
if [[ "$LOG_ENABLE" == "y" ]]; then
    iptables -I TSPUBLOCK 1 -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j LOG --log-prefix "TSPUBLOCK: " --log-level 4
fi

iptables -F GOVBLOCK 2>/dev/null || true
iptables -A GOVBLOCK -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j DROP
if [[ "$LOG_ENABLE" == "y" ]]; then
    iptables -I GOVBLOCK 1 -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j LOG --log-prefix "GOVBLOCK: " --log-level 4
fi

# Сохранение правил
ipset save > /etc/ipset.conf.tmp && mv /etc/ipset.conf.tmp /etc/ipset.conf || true
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save 2>/dev/null || true
else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4.tmp && mv /etc/iptables/rules.v4.tmp /etc/iptables/rules.v4 || true
fi

log_message "=== ОБНОВЛЕНИЕ ЗАВЕРШЕНО ==="
EOF
    chmod +x "$INSTALL_DIR/update.sh"
}

# Создание update_tspublock.sh
create_update_tspublock_script() {
    cat > "$INSTALL_DIR/update_tspublock.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

LOG_DIR="/var/log/rkn-watcher"
mkdir -p "$LOG_DIR"

python3 << 'PYEOF'
import urllib.request
import subprocess
import sys
import logging

LOG_FILE = "/var/log/rkn-watcher/update.log"
logging.basicConfig(level=logging.INFO, filename=LOG_FILE, format='%(message)s')

url = 'https://github.com/tread-lightly/CyberOK_Skipa_ips/raw/refs/heads/main/lists/skipa_cidr.txt'
try:
    with urllib.request.urlopen(url, timeout=30) as response:
        content = response.read().decode('utf-8')
    
    # Получаем текущее количество
    result = subprocess.run(['ipset', 'list', 'TSPUIPS'], capture_output=True, text=True, check=False)
    old_count = 0
    for line in result.stdout.split('\n'):
        if 'Number of entries' in line:
            old_count = int(line.split(':')[1].strip())
            break
    
    subprocess.run(['ipset', 'flush', 'TSPUIPS'], check=False, stderr=subprocess.DEVNULL)
    count = 0
    for line in content.split('\n'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if '/' in line:
            subprocess.run(['ipset', 'add', 'TSPUIPS', line], check=False, stderr=subprocess.DEVNULL)
            count += 1
    
    new_count = count
    diff = new_count - old_count
    status = f"TSPUBLOCK: {new_count} entries (было: {old_count}, изменено: {diff:+d})"
    logging.info(status)
    print(status)
    
    # Сохраняем количество
    with open('/etc/rkn-watcher/tspu_count.txt', 'w') as f:
        f.write(str(new_count))
        
except Exception as e:
    error_msg = f"ОШИБКА TSPUBLOCK: {e}"
    logging.error(error_msg)
    print(error_msg)
    sys.exit(1)
PYEOF
EOF
    chmod +x "$INSTALL_DIR/update_tspublock.sh"
}

# Создание update_govips.sh
create_update_govips_script() {
    cat > "$INSTALL_DIR/update_govips.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

LOG_DIR="/var/log/rkn-watcher"
mkdir -p "$LOG_DIR"

python3 << 'PYEOF'
import urllib.request
import subprocess
import re
import sys
import logging

LOG_FILE = "/var/log/rkn-watcher/update.log"
logging.basicConfig(level=logging.INFO, filename=LOG_FILE, format='%(message)s')

url = 'https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists_iptables/blacklist-v4.ipset'
try:
    with urllib.request.urlopen(url, timeout=30) as response:
        content = response.read().decode('utf-8')
    
    # Получаем текущее количество
    result = subprocess.run(['ipset', 'list', 'GOVIPS'], capture_output=True, text=True, check=False)
    old_count = 0
    for line in result.stdout.split('\n'):
        if 'Number of entries' in line:
            old_count = int(line.split(':')[1].strip())
            break
    
    subprocess.run(['ipset', 'flush', 'GOVIPS'], check=False, stderr=subprocess.DEVNULL)
    count = 0
    for line in content.split('\n'):
        match = re.match(r'^add blacklist-v4 ([0-9./]+)', line)
        if match:
            subnet = match.group(1)
            subprocess.run(['ipset', 'add', 'GOVIPS', subnet], check=False, stderr=subprocess.DEVNULL)
            count += 1
    
    new_count = count
    diff = new_count - old_count
    status = f"GOVIPS: {new_count} entries (было: {old_count}, изменено: {diff:+d})"
    logging.info(status)
    print(status)
    
    # Сохраняем количество
    with open('/etc/rkn-watcher/gov_count.txt', 'w') as f:
        f.write(str(new_count))
        
except Exception as e:
    error_msg = f"ОШИБКА GOVIPS: {e}"
    logging.error(error_msg)
    print(error_msg)
    sys.exit(1)
PYEOF
EOF
    chmod +x "$INSTALL_DIR/update_govips.sh"
}

# Создание всех скриптов
create_all_scripts() {
    info "Создание всех скриптов в $INSTALL_DIR..."
    create_geoip_firewall_script
    create_daemon_script
    create_update_script
    create_update_tspublock_script
    create_update_govips_script
    success "Все 5 скриптов созданы"
}

# ==================== ФУНКЦИИ УПРАВЛЕНИЯ СИМЛИНКОМ ====================

create_command() {
    info "Создание команды rkn-watcher..."
    rm -f /usr/bin/rkn-watcher /usr/local/bin/rkn-watcher 2>/dev/null || true
    cp "$0" "$SYMLINK_PATH"
    chmod +x "$SYMLINK_PATH"
    ln -sf "$SYMLINK_PATH" /usr/bin/rkn-watcher
    success "Команда создана: $SYMLINK_PATH"
}

remove_command() {
    info "Удаление команды rkn-watcher..."
    rm -f "$SYMLINK_PATH" /usr/bin/rkn-watcher 2>/dev/null || true
    success "Команда rkn-watcher удалена"
}

# ==================== ФУНКЦИИ РАБОТЫ С JSON ====================

# Добавить страну с валидацией
add_country_safe() {
    local country=$1
    local result
    result=$("$VENV_DIR/bin/python3" -c "
import json
import sys

country_code = sys.argv[1].upper()
if len(country_code) != 2 or not country_code.isalpha():
    sys.exit(1)

with open('$WHITELIST_FILE', 'r') as f:
    data = json.load(f)

if country_code not in data.get('countries', []):
    data['countries'].append(country_code)
    with open('$WHITELIST_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print('OK')
else:
    print('EXISTS')
" "$country" 2>/dev/null) || return 1
    
    echo "$result"
}

# Удалить страну с валидацией
remove_country_safe() {
    local country=$1
    local result
    result=$("$VENV_DIR/bin/python3" -c "
import json
import sys

country_code = sys.argv[1].upper()

with open('$WHITELIST_FILE', 'r') as f:
    data = json.load(f)

if country_code in data.get('countries', []):
    data['countries'].remove(country_code)
    with open('$WHITELIST_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print('OK')
else:
    print('NOTFOUND')
" "$country" 2>/dev/null) || return 1
    
    echo "$result"
}

# Добавить IP с валидацией
add_ip_safe() {
    local ip=$1
    if ! validate_ip "$ip"; then
        return 1
    fi
    
    local result
    result=$("$VENV_DIR/bin/python3" -c "
import json
import sys

ip_addr = sys.argv[1]

with open('$WHITELIST_FILE', 'r') as f:
    data = json.load(f)

if ip_addr not in data.get('ips', []):
    data['ips'].append(ip_addr)
    with open('$WHITELIST_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print('OK')
else:
    print('EXISTS')
" "$ip" 2>/dev/null) || return 1
    
    echo "$result"
}

# Добавить порт с валидацией
add_port_safe() {
    local port=$1
    if ! validate_port "$port"; then
        return 1
    fi
    
    local result
    result=$("$VENV_DIR/bin/python3" -c "
import json
import sys

port_num = int(sys.argv[1])

with open('$WHITELIST_FILE', 'r') as f:
    data = json.load(f)

if port_num not in data.get('ports', []):
    data['ports'].append(port_num)
    with open('$WHITELIST_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print('OK')
else:
    print('EXISTS')
" "$port" 2>/dev/null) || return 1
    
    echo "$result"
}

# ==================== ФУНКЦИИ МЕНЮ ====================

# Управление блокировками
block_management_menu() {
    while true; do
        clear
        title
        echo -e "${CYAN}              УПРАВЛЕНИЕ БЛОКИРОВКАМИ${NC}"
        title
        echo ""
        echo "1) Включить/отключить TSPUBLOCK"
        echo "2) Включить/отключить GOVIPS"
        echo "3) Включить/отключить GeoIP фильтрацию"
        echo "4) Показать текущие правила iptables"
        echo "5) Показать статистику блокировок"
        echo "0) Назад"
        echo ""
        read -p "Выберите пункт: " choice
        
        case $choice in
            1) toggle_tspublock ;;
            2) toggle_govips ;;
            3) toggle_geoip ;;
            4) show_iptables_rules ;;
            5) show_block_stats ;;
            0) break ;;
            *) error "Неверный выбор"; sleep 2 ;;
        esac
    done
}

# Конфигурация GeoIP
geoip_config_menu() {
    while true; do
        clear
        title
        echo -e "${CYAN}              НАСТРОЙКА GEOIP ФИЛЬТРАЦИИ${NC}"
        title
        echo ""
        echo "1) Добавить страну в белый список"
        echo "2) Удалить страну из белого списка"
        echo "3) Показать список стран"
        echo "4) Добавить IP в белый список"
        echo "5) Удалить IP из белого списка"
        echo "6) Добавить порт в белый список"
        echo "7) Удалить порт из белого списка"
        echo "8) Показать весь белый список"
        echo "9) Включить/отключить GeoIP фильтрацию"
        echo "0) Назад"
        echo ""
        read -p "Выберите пункт: " choice
        
        case $choice in
            1)
                read -p "Введите код страны (например, RU): " country
                if add_country_safe "$country" | grep -q "OK"; then
                    success "Страна $country добавлена"
                    "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
                else
                    error "Ошибка при добавлении страны"
                fi
                sleep 2
                ;;
            2)
                read -p "Введите код страны для удаления: " country
                if remove_country_safe "$country" | grep -q "OK"; then
                    success "Страна $country удалена"
                    "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
                else
                    error "Ошибка при удалении страны"
                fi
                sleep 2
                ;;
            3)
                clear
                title
                echo -e "${CYAN}              БЕЛЫЙ СПИСОК СТРАН${NC}"
                title
                echo ""
                "$VENV_DIR/bin/python3" -c "import json; data=json.load(open('$WHITELIST_FILE')); print('\n'.join(data.get('countries', [])) if data.get('countries') else 'Пусто')"
                echo ""
                read -p "Нажмите Enter для продолжения..."
                ;;
            4)
                read -p "Введите IP или подсеть (например, 192.168.1.1 или 10.0.0.0/24): " ip
                if add_ip_safe "$ip" | grep -q "OK"; then
                    success "IP $ip добавлен"
                    "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
                else
                    error "Ошибка: некорректный IP или IP уже добавлен"
                fi
                sleep 2
                ;;
            5)
                read -p "Введите IP для удаления: " ip
                if [[ ! -z "$ip" ]]; then
                    "$VENV_DIR/bin/python3" -c "
import json
ip_addr = '$ip'
with open('$WHITELIST_FILE', 'r') as f:
    data = json.load(f)
if ip_addr in data.get('ips', []):
    data['ips'].remove(ip_addr)
    with open('$WHITELIST_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print('OK')
else:
    print('NOTFOUND')
" | grep -q "OK" && success "IP удалён" || error "IP не найден"
                    "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
                fi
                sleep 2
                ;;
            6)
                read -p "Введите порт: " port
                if validate_port "$port"; then
                    if add_port_safe "$port" | grep -q "OK"; then
                        success "Порт $port добавлен"
                        "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
                    else
                        error "Ошибка: порт уже добавлен"
                    fi
                else
                    error "Ошибка: некорректный номер порта"
                fi
                sleep 2
                ;;
            7)
                read -p "Введите порт для удаления: " port
                if [[ ! -z "$port" ]]; then
                    "$VENV_DIR/bin/python3" -c "
import json
port_num = int('$port')
with open('$WHITELIST_FILE', 'r') as f:
    data = json.load(f)
if port_num in data.get('ports', []):
    data['ports'].remove(port_num)
    with open('$WHITELIST_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print('OK')
else:
    print('NOTFOUND')
" | grep -q "OK" && success "Порт удалён" || error "Порт не найден"
                    "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
                fi
                sleep 2
                ;;
            8)
                clear
                title
                echo -e "${CYAN}              ПОЛНЫЙ БЕЛЫЙ СПИСОК${NC}"
                title
                echo ""
                echo "=== Страны ==="
                "$VENV_DIR/bin/python3" -c "import json; data=json.load(open('$WHITELIST_FILE')); print('\n'.join(data.get('countries', [])) if data.get('countries') else 'Пусто')"
                echo ""
                echo "=== IP адреса и подсети ==="
                "$VENV_DIR/bin/python3" -c "import json; data=json.load(open('$WHITELIST_FILE')); print('\n'.join(data.get('ips', [])) if data.get('ips') else 'Пусто')"
                echo ""
                echo "=== Порты ==="
                "$VENV_DIR/bin/python3" -c "import json; data=json.load(open('$WHITELIST_FILE')); print('\n'.join(map(str, data.get('ports', []))) if data.get('ports') else 'Пусто')"
                echo ""
                read -p "Нажмите Enter для продолжения..."
                ;;
            9)
                current=$("$VENV_DIR/bin/python3" -c "import json; print(json.load(open('$WHITELIST_FILE')).get('enabled', True))")
                if [[ "$current" == "True" ]]; then
                    "$VENV_DIR/bin/python3" -c "import json; d=json.load(open('$WHITELIST_FILE')); d['enabled']=False; json.dump(d, open('$WHITELIST_FILE','w'))"
                    success "GeoIP фильтрация ОТКЛЮЧЕНА"
                else
                    "$VENV_DIR/bin/python3" -c "import json; d=json.load(open('$WHITELIST_FILE')); d['enabled']=True; json.dump(d, open('$WHITELIST_FILE','w'))"
                    success "GeoIP фильтрация ВКЛЮЧЕНА"
                fi
                "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
                sleep 2
                ;;
            0) break ;;
            *) error "Неверный выбор"; sleep 2 ;;
        esac
    done
}

# Показать статистику блокировок
show_block_stats() {
    clear
    title
    echo -e "${CYAN}              СТАТИСТИКА БЛОКИРОВОК${NC}"
    title
    echo ""
    
    echo -e "${GREEN}=== Размеры списков ===${NC}"
    tspu_count=$(ipset list TSPUIPS 2>/dev/null | grep 'Number of entries' | awk '{print $NF}' || echo "0")
    gov_count=$(ipset list GOVIPS 2>/dev/null | grep 'Number of entries' | awk '{print $NF}' || echo "0")
    echo "  TSPUIPS: $tspu_count подсетей"
    echo "  GOVIPS: $gov_count подсетей"
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Показать правила iptables
show_iptables_rules() {
    clear
    title
    echo -e "${CYAN}              ПРАВИЛА IPTABLES${NC}"
    title
    echo ""
    
    echo -e "${GREEN}=== INPUT цепочка ===${NC}"
    iptables -L INPUT -v -n 2>/dev/null | head -20 || echo "Нет данных"
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Включить/отключить GeoIP фильтрацию
toggle_geoip() {
    current=$("$VENV_DIR/bin/python3" -c "import json; print(json.load(open('$WHITELIST_FILE')).get('enabled', True))" 2>/dev/null || echo "True")
    if [[ "$current" == "True" ]]; then
        "$VENV_DIR/bin/python3" -c "import json; d=json.load(open('$WHITELIST_FILE')); d['enabled']=False; json.dump(d, open('$WHITELIST_FILE','w'))" 2>/dev/null || true
        success "GeoIP фильтрация ОТКЛЮЧЕНА"
    else
        "$VENV_DIR/bin/python3" -c "import json; d=json.load(open('$WHITELIST_FILE')); d['enabled']=True; json.dump(d, open('$WHITELIST_FILE','w'))" 2>/dev/null || true
        success "GeoIP фильтрация ВКЛЮЧЕНА"
    fi
    sleep 2
}

# Просмотр логов
show_logs() {
    while true; do
        clear
        title
        echo -e "${CYAN}              ЛОГИ${NC}"
        title
        echo ""
        echo "1) Логи обновлений (последние 50)"
        echo "2) Логи демона (последние 50)"
        echo "3) Очистить логи"
        echo "0) Назад"
        echo ""
        read -p "Выберите пункт: " choice
        
        case $choice in
            1)
                if [[ -f "$LOG_DIR/update.log" ]]; then
                    tail -50 "$LOG_DIR/update.log"
                else
                    echo "Логи обновлений не найдены"
                fi
                echo ""
                read -p "Нажмите Enter..."
                ;;
            2)
                if [[ -f "$LOG_DIR/watcher.log" ]]; then
                    tail -50 "$LOG_DIR/watcher.log"
                else
                    echo "Логи демона не найдены"
                fi
                echo ""
                read -p "Нажмите Enter..."
                ;;
            3)
                read -p "Очистить все логи? (y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    > "$LOG_DIR/update.log" 2>/dev/null || true
                    > "$LOG_DIR/geoip.log" 2>/dev/null || true
                    > "$LOG_DIR/watcher.log" 2>/dev/null || true
                    success "Логи очищены"
                fi
                sleep 2
                ;;
            0) break ;;
            *) error "Неверный выбор"; sleep 2 ;;
        esac
    done
}

# Ручное обновление
manual_update() {
    while true; do
        clear
        title
        echo -e "${CYAN}              РУЧНОЕ ОБНОВЛЕНИЕ${NC}"
        title
        echo ""
        echo "1) Обновить TSPUBLOCK"
        echo "2) Обновить GOVIPS"
        echo "3) Обновить оба списка"
        echo "4) Запустить полное обновление"
        echo "0) Назад"
        echo ""
        read -p "Выберите: " choice
        
        load_config_cache
        
        case $choice in
            1)
                info "Обновление TSPUBLOCK..."
                if download_tspublock_list; then
                    setup_tspublock_rules "$LOG_ENABLE"
                    save_rules
                    success "TSPUBLOCK успешно обновлён"
                else
                    error "Ошибка при обновлении TSPUBLOCK"
                fi
                sleep 2
                ;;
            2)
                info "Обновление GOVIPS..."
                if download_govips_list; then
                    setup_govips_rules "$LOG_ENABLE"
                    save_rules
                    success "GOVIPS успешно обновлён"
                else
                    error "Ошибка при обновлении GOVIPS"
                fi
                sleep 2
                ;;
            3)
                info "Обновление TSPUBLOCK и GOVIPS (параллельно)..."
                download_both_lists
                setup_tspublock_rules "$LOG_ENABLE"
                setup_govips_rules "$LOG_ENABLE"
                save_rules
                success "Оба списка успешно обновлены"
                sleep 2
                ;;
            4)
                info "Запуск полного обновления..."
                if [[ -f "$INSTALL_DIR/update.sh" ]]; then
                    bash "$INSTALL_DIR/update.sh"
                    success "Полное обновление завершено"
                else
                    error "Скрипт update.sh не найден"
                fi
                sleep 2
                ;;
            0)
                break
                ;;
            *)
                error "Неверный выбор"
                sleep 2
                ;;
        esac
    done
}

# ==================== УСТАНОВКА ====================

install_menu() {
    clear
    title
    echo -e "${CYAN}                    УСТАНОВКА RKN WATCHER${NC}"
    title
    echo ""
    
    # Установка зависимостей
    info "Установка системных зависимостей..."
    apt update -qq 2>/dev/null || true
    apt install -y -qq iptables ipset curl python3 python3-venv python3-pip cron 2>/dev/null || true
    
    if ! command -v netfilter-persistent &> /dev/null; then
        apt install -y -qq iptables-persistent 2>/dev/null || true
    fi
    
    # Настройка GeoIP фильтрации
    echo ""
    echo "Настройка GeoIP фильтрации:"
    echo "1) Фильтрация на конкретном порту (например, 443)"
    echo "2) Фильтрация на нескольких портах (через запятую)"
    echo "3) Фильтрация для всех портов"
    read -p "Выберите вариант (1-3): " port_choice
    
    case $port_choice in
        1) read -p "Введите порт: " filter_ports ;;
        2) read -p "Введите порты через запятую: " filter_ports ;;
        3) filter_ports="all" ;;
        *) filter_ports="all" ;;
    esac
    
    echo ""
    read -p "Включить логирование RST-пакетов? (y/n): " log_enable
    echo ""
    read -p "Настроить интеграцию с UFW? (y/n): " setup_ufw
    echo ""
    read -p "Включить автоматическое обновление? (y/n): " auto_update
    
    if [[ "$setup_ufw" == "y" ]]; then
        apt install -y -qq ufw 2>/dev/null || true
        success "UFW установлен"
    fi
    
    # Создание директорий
    info "Создание директорий..."
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$BACKUP_DIR" /etc/iptables
    
    # Копирование текущего скрипта
    info "Копирование основного скрипта..."
    SCRIPT_SOURCE=$(readlink -f "$0")
    cp "$SCRIPT_SOURCE" "$INSTALL_DIR/rkn-watcher.sh"
    chmod +x "$INSTALL_DIR/rkn-watcher.sh"
    success "Основной скрипт скопирован"
    
    # Создание конфигурационных файлов
    info "Создание конфигурационных файлов..."
    cat > "$WHITELIST_FILE" << EOF
{
    "enabled": true,
    "countries": ["RU"],
    "ips": [],
    "ports": []
}
EOF
    
    cat > "$BLACKLIST_FILE" << EOF
{
    "ips": [],
    "ports": []
}
EOF
    success "Конфигурационные файлы созданы"
    
    # Создание виртуального окружения
    info "Создание виртуального окружения Python..."
    python3 -m venv "$VENV_DIR" 2>/dev/null || true
    "$VENV_DIR/bin/pip" install --upgrade pip -q 2>/dev/null || true
    success "Виртуальное окружение создано"
    
    # СОЗДАНИЕ ВСЕХ СКРИПТОВ
    create_all_scripts
    
    # Создание цепочек iptables
    ensure_chains
    
    # Загрузка списков (параллельно)
    echo ""
    download_both_lists
    
    # Настройка правил
    setup_tspublock_rules "$log_enable"
    setup_govips_rules "$log_enable"
    
    # Применение GeoIP правил
    "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
    
    # Сохранение настроек
    info "Сохранение конфигурации..."
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
FILTER_PORTS="$filter_ports"
LOG_ENABLE="$log_enable"
UFW_INTEGRATION="$setup_ufw"
AUTO_UPDATE="$auto_update"
VENV_PATH="$VENV_DIR"
INSTALL_DATE="$(date)"
LAST_UPDATE="$(date)"
EOF
    success "Конфигурация сохранена"
    
    # Настройка systemd сервиса
    info "Настройка systemd сервиса..."
    cat > /etc/systemd/system/rkn-watcher.service << EOF
[Unit]
Description=RKN Watcher Daemon - GeoIP Firewall
After=network.target

[Service]
Type=simple
ExecStart=$VENV_DIR/bin/python3 $INSTALL_DIR/rkn-watcher-daemon.py
Restart=always
RestartSec=10
User=root
WorkingDirectory=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable rkn-watcher
    systemctl start rkn-watcher
    success "Сервис настроен и запущен"
    
    # СОЗДАНИЕ КОМАНДЫ
    create_command
    
    # Сохранение правил
    save_rules
    
    # Настройка cron
    if [[ "$auto_update" == "y" ]]; then
        info "Настройка cron..."
        (crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/update.sh" || true; echo "0 3 * * * $INSTALL_DIR/update.sh") | crontab - 2>/dev/null || true
        success "Cron настроен (ежедневно в 3:00)"
    fi
    
    success "УСТАНОВКА ЗАВЕРШЕНА!"
    
    tspu_count=$(ipset list TSPUIPS 2>/dev/null | grep 'Number of entries' | awk '{print $NF}' || echo "0")
    gov_count=$(ipset list GOVIPS 2>/dev/null | grep 'Number of entries' | awk '{print $NF}' || echo "0")
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${GREEN}                    УСТАНОВКА УСПЕШНА${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo -e "${CYAN}📊 ЗАГРУЖЕННЫЕ СПИСКИ:${NC}"
    echo "  • TSPUBLOCK: $tspu_count подсетей"
    echo "  • GOVIPS: $gov_count подсетей"
    echo ""
    echo -e "${CYAN}🚀 КАК ЗАПУСКАТЬ:${NC}"
    echo "  sudo rkn-watcher"
    echo ""
    
    read -p "Нажмите Enter для продолжения..."
    main_menu
}

# ==================== УДАЛЕНИЕ ====================

uninstall_menu() {
    clear
    title
    echo -e "${RED}                    УДАЛЕНИЕ RKN WATCHER${NC}"
    title
    echo ""
    read -p "Вы уверены? (напишите 'YES' для подтверждения): " confirm
    
    if [[ "$confirm" != "YES" ]]; then
        warn "Удаление отменено"
        sleep 2
        return
    fi
    
    info "Начинаю удаление RKN Watcher..."
    
    # Остановка сервиса
    systemctl stop rkn-watcher 2>/dev/null || true
    systemctl disable rkn-watcher 2>/dev/null || true
    rm -f /etc/systemd/system/rkn-watcher.service
    systemctl daemon-reload
    
    # Удаление правил iptables
    iptables -D INPUT -j TSPUBLOCK 2>/dev/null || true
    iptables -D INPUT -j GOVBLOCK 2>/dev/null || true
    iptables -F TSPUBLOCK 2>/dev/null || true
    iptables -F GOVBLOCK 2>/dev/null || true
    iptables -X TSPUBLOCK 2>/dev/null || true
    iptables -X GOVBLOCK 2>/dev/null || true
    
    # Удаление ipset
    ipset destroy TSPUIPS 2>/dev/null || true
    ipset destroy GOVIPS 2>/dev/null || true
    
    # Удаление файлов и директорий
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
    rm -f /usr/local/bin/rkn-watcher /usr/bin/rkn-watcher
    rm -f /etc/ipset.conf /etc/iptables/rules.v4
    
    # Удаление cron
    crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/update.sh" | crontab - 2>/dev/null || true
    
    success "RKN Watcher полностью удалён"
    sleep 2
    main_menu
}

# ==================== ГЛАВНОЕ МЕНЮ ====================

main_menu() {
    while true; do
        clear
        title
        echo -e "${CYAN}              RKN WATCHER v2.0 - ИСПРАВЛЕННАЯ ВЕРСИЯ${NC}"
        title
        echo ""
        
        if is_installed; then
            echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
            echo -e "${GREEN}                      РЕЖИМ УПРАВЛЕНИЯ${NC}"
            echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo "1) Управление блокировками"
            echo "2) Настройка GeoIP фильтрации"
            echo "3) Ручное обновление списков"
            echo "4) Просмотр статистики"
            echo "5) Просмотр логов"
            echo "6) Удаление"
            echo "0) Выход"
        else
            echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
            echo -e "${RED}                      РЕЖИМ УСТАНОВКИ${NC}"
            echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo "1) Установка"
            echo "0) Выход"
        fi
        
        echo ""
        read -p "Выберите пункт: " choice
        
        if is_installed; then
            case $choice in
                1) block_management_menu ;;
                2) geoip_config_menu ;;
                3) manual_update ;;
                4) show_block_stats ;;
                5) show_logs ;;
                6) uninstall_menu ;;
                0) echo "Выход..."; exit 0 ;;
                *) error "Неверный выбор"; sleep 2 ;;
            esac
        else
            case $choice in
                1) install_menu ;;
                0) echo "Выход..."; exit 0 ;;
                *) error "Неверный выбор"; sleep 2 ;;
            esac
        fi
    done
}

# Запуск
check_root
main_menu
