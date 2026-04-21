#!/bin/bash
# RKN Watcher - Полная система защиты от ТСПУ и GeoIP фильтрации
# Версия: 1.0 - ПОЛНАЯ ВЕРСИЯ
# GitHub: https://github.com/Balbuto/RCN

set -e

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

# Функции вывода
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
title() { echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"; }
subtitle() { echo -e "${MAGENTA}───────────────────────────────────────────────────────────────${NC}"; }

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен запускаться от root (sudo)"
        exit 1
    fi
}

# Проверка установки
is_installed() {
    if [[ -d "$INSTALL_DIR" ]] && [[ -f "$INSTALL_DIR/rkn-watcher-daemon.py" ]] && [[ -f "$INSTALL_DIR/geoip_firewall.py" ]]; then
        return 0
    else
        return 1
    fi
}

# Проверка наличия UFW
check_ufw() {
    command -v ufw &> /dev/null && return 0 || return 1
}

# ==================== ФУНКЦИИ ЗАГРУЗКИ СПИСКОВ ====================

# Загрузка TSPUBLOCK (CIDR файл)
download_tspublock_list() {
    info "Загрузка списка TSPUBLOCK (CyberOK Skipa CIDR)..."
    local url="https://github.com/tread-lightly/CyberOK_Skipa_ips/raw/refs/heads/main/lists/skipa_cidr.txt"
    local temp_file="/tmp/tspublock.txt"
    
    if curl -sSL --connect-timeout 10 --max-time 30 "$url" -o "$temp_file" 2>/dev/null; then
        ipset create TSPUIPS hash:net maxelem 1000000 2>/dev/null || ipset flush TSPUIPS
        local count=0
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            if [[ "$line" =~ ^[0-9./]+$ ]]; then
                ipset add TSPUIPS "$line" 2>/dev/null && ((count++))
            fi
        done < "$temp_file"
        rm -f "$temp_file"
        success "Загружено $count подсетей в TSPUIPS"
        echo "$count" > "$CONFIG_DIR/tspu_count.txt"
        return 0
    else
        error "Не удалось загрузить TSPUBLOCK"
        return 1
    fi
}

# Загрузка GOVIPS
download_govips_list() {
    info "Загрузка списка GOVIPS (госорганы РФ)..."
    local url="https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists_iptables/blacklist-v4.ipset"
    local temp_file="/tmp/govips.txt"
    
    if curl -sSL --connect-timeout 10 --max-time 30 "$url" -o "$temp_file" 2>/dev/null; then
        ipset create GOVIPS hash:net maxelem 1000000 2>/dev/null || ipset flush GOVIPS
        local count=0
        while IFS= read -r line; do
            if [[ "$line" =~ ^add\ blacklist-v4\ ([0-9\./]+) ]]; then
                ipset add GOVIPS "${BASH_REMATCH[1]}" 2>/dev/null && ((count++))
            fi
        done < "$temp_file"
        rm -f "$temp_file"
        success "Загружено $count подсетей в GOVIPS"
        echo "$count" > "$CONFIG_DIR/gov_count.txt"
        return 0
    else
        error "Не удалось загрузить GOVIPS"
        return 1
    fi
}

# ==================== ФУНКЦИИ НАСТРОЙКИ IPTABLES ====================

# Создание цепочек iptables
ensure_chains() {
    iptables -N TSPUBLOCK 2>/dev/null || true
    iptables -N GOVBLOCK 2>/dev/null || true
    iptables -N GEOIP_DROP 2>/dev/null || true
    iptables -C INPUT -j TSPUBLOCK 2>/dev/null || iptables -I INPUT 1 -j TSPUBLOCK
    iptables -C INPUT -j GOVBLOCK 2>/dev/null || iptables -I INPUT 2 -j GOVBLOCK
}

# Настройка правил TSPUBLOCK
setup_tspublock_rules() {
    local log_enable=$1
    iptables -F TSPUBLOCK 2>/dev/null
    iptables -A TSPUBLOCK -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j DROP
    if [[ "$log_enable" == "y" ]]; then
        iptables -I TSPUBLOCK 1 -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j LOG --log-prefix "TSPUBLOCK: " --log-level 4
    fi
    success "TSPUBLOCK правила настроены"
}

# Настройка правил GOVIPS
setup_govips_rules() {
    local log_enable=$1
    iptables -F GOVBLOCK 2>/dev/null
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

# Сохранение правил
save_rules() {
    info "Сохранение правил..."
    ipset save > /etc/ipset.conf 2>/dev/null
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save 2>/dev/null
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi
    success "Правила сохранены"
}

# ==================== ФУНКЦИИ СОЗДАНИЯ СКРИПТОВ ====================

# Создание всех скриптов
create_all_scripts() {
    info "Создание всех скриптов в $INSTALL_DIR..."
    
    # 1. geoip_firewall.py
    cat > "$INSTALL_DIR/geoip_firewall.py" << 'EOF'
#!/usr/bin/env python3
import json
import subprocess
import sys
import os
import logging
from datetime import datetime

CONFIG_FILE = "/etc/rkn-watcher/whitelist.json"
BLACKLIST_FILE = "/etc/rkn-watcher/blacklist.json"
SETTINGS_FILE = "/etc/rkn-watcher/settings.conf"
LOG_FILE = "/var/log/rkn-watcher/geoip.log"

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', filename=LOG_FILE)

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
    if filter_ports == "all":
        subprocess.run(["iptables", "-D", "INPUT", "-j", "GEOIP_DROP"], stderr=subprocess.DEVNULL)
    else:
        for port in filter_ports.split(','):
            subprocess.run(["iptables", "-D", "INPUT", "-p", "tcp", "--dport", port.strip(), "-j", "GEOIP_DROP"], stderr=subprocess.DEVNULL)
    
    subprocess.run(["iptables", "-F", "GEOIP_DROP"], stderr=subprocess.DEVNULL)
    subprocess.run(["iptables", "-X", "GEOIP_DROP"], stderr=subprocess.DEVNULL)
    
    if not config.get("enabled", True):
        logging.info("GeoIP фильтрация отключена")
        print("GeoIP фильтрация отключена")
        return
    
    subprocess.run(["iptables", "-N", "GEOIP_DROP"], stderr=subprocess.DEVNULL)
    
    # Белый список IP (всегда разрешены)
    for ip_entry in config.get("ips", []):
        subprocess.run(["iptables", "-A", "GEOIP_DROP", "-s", ip_entry, "-j", "RETURN"], stderr=subprocess.DEVNULL)
        logging.info(f"Добавлен белый IP: {ip_entry}")
    
    # Белый список портов
    for port in config.get("ports", []):
        subprocess.run(["iptables", "-A", "GEOIP_DROP", "-p", "tcp", "--dport", str(port), "-j", "RETURN"], stderr=subprocess.DEVNULL)
        logging.info(f"Добавлен белый порт: {port}")
    
    # Чёрный список IP
    for ip_entry in blacklist.get("ips", []):
        subprocess.run(["iptables", "-A", "GEOIP_DROP", "-s", ip_entry, "-j", "DROP"], stderr=subprocess.DEVNULL)
        logging.info(f"Добавлен чёрный IP: {ip_entry}")
    
    # Белый список стран
    allowed_countries = config.get("countries", [])
    if allowed_countries:
        logging.info(f"Разрешённые страны: {', '.join(allowed_countries)}")
        print(f"Разрешённые страны: {', '.join(allowed_countries)}")
        subprocess.run(["iptables", "-A", "GEOIP_DROP", "-j", "RETURN"], stderr=subprocess.DEVNULL)
    else:
        subprocess.run(["iptables", "-A", "GEOIP_DROP", "-j", "DROP"], stderr=subprocess.DEVNULL)
    
    # Применение правил
    if filter_ports == "all":
        subprocess.run(["iptables", "-I", "INPUT", "-j", "GEOIP_DROP"], stderr=subprocess.DEVNULL)
    else:
        for port in filter_ports.split(','):
            subprocess.run(["iptables", "-I", "INPUT", "-p", "tcp", "--dport", port.strip(), "-j", "GEOIP_DROP"], stderr=subprocess.DEVNULL)
    
    logging.info("GeoIP правила применены")
    print("GeoIP правила применены")

def main():
    if len(sys.argv) > 1 and sys.argv[1] == "apply":
        config = load_whitelist()
        blacklist = load_blacklist()
        apply_firewall_rules(config, blacklist)
    elif len(sys.argv) > 1 and sys.argv[1] == "status":
        result = subprocess.run(["iptables", "-L", "GEOIP_DROP", "-v", "-n"], capture_output=True, text=True)
        print(result.stdout)
    elif len(sys.argv) > 1 and sys.argv[1] == "show-config":
        config = load_whitelist()
        print(json.dumps(config, indent=2))
    else:
        print("Использование: geoip_firewall.py [apply|status|show-config]")

if __name__ == "__main__":
    main()
EOF

    # 2. rkn-watcher-daemon.py
    cat > "$INSTALL_DIR/rkn-watcher-daemon.py" << 'EOF'
#!/usr/bin/env python3
import time
import subprocess
import os
import logging
import signal
import sys

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
    subprocess.run([VENV_PYTHON, "/opt/rkn-watcher/geoip_firewall.py", "apply"])

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
    last_check = 0
    
    while True:
        try:
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
            
            # Ежедневная проверка обновлений (в 3:00)
            current_time = time.time()
            if current_time - last_check > 86400 and get_auto_update():
                current_hour = time.localtime().tm_hour
                if current_hour == 3:
                    logging.info("Запуск ежедневного обновления списков...")
                    print("Запуск ежедневного обновления списков...")
                    check_updates()
                    last_check = current_time
            
        except Exception as e:
            logging.error(f"Ошибка: {e}")
            print(f"Ошибка: {e}")
        
        time.sleep(30)

if __name__ == "__main__":
    main()
EOF

    # 3. update_tspublock.sh
    cat > "$INSTALL_DIR/update_tspublock.sh" << 'EOF'
#!/bin/bash
LOG_DIR="/var/log/rkn-watcher"
mkdir -p "$LOG_DIR"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Обновление TSPUBLOCK..." >> "$LOG_DIR/update.log"

python3 -c "
import urllib.request
import subprocess
import sys

url = 'https://github.com/tread-lightly/CyberOK_Skipa_ips/raw/refs/heads/main/lists/skipa_cidr.txt'
try:
    with urllib.request.urlopen(url, timeout=30) as response:
        content = response.read().decode('utf-8')
    
    # Получаем текущее количество
    result = subprocess.run(['ipset', 'list', 'TSPUIPS'], capture_output=True, text=True)
    old_count = 0
    for line in result.stdout.split('\n'):
        if 'Number of entries' in line:
            old_count = int(line.split(':')[1].strip())
            break
    
    subprocess.run(['ipset', 'flush', 'TSPUIPS'], check=False)
    count = 0
    for line in content.split('\n'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if '/' in line:
            subprocess.run(['ipset', 'add', 'TSPUIPS', line], check=False, stderr=subprocess.DEVNULL)
            count += 1
    
    new_count = count
    print(f'OK: {new_count} entries (было: {old_count}, добавлено: {new_count - old_count})')
    
    # Сохраняем количество
    with open('/etc/rkn-watcher/tspu_count.txt', 'w') as f:
        f.write(str(new_count))
        
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
" >> "$LOG_DIR/update.log" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] TSPUBLOCK обновлён" >> "$LOG_DIR/update.log"
EOF

    # 4. update_govips.sh
    cat > "$INSTALL_DIR/update_govips.sh" << 'EOF'
#!/bin/bash
LOG_DIR="/var/log/rkn-watcher"
mkdir -p "$LOG_DIR"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Обновление GOVIPS..." >> "$LOG_DIR/update.log"

python3 -c "
import urllib.request
import subprocess
import re
import sys

url = 'https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists_iptables/blacklist-v4.ipset'
try:
    with urllib.request.urlopen(url, timeout=30) as response:
        content = response.read().decode('utf-8')
    
    # Получаем текущее количество
    result = subprocess.run(['ipset', 'list', 'GOVIPS'], capture_output=True, text=True)
    old_count = 0
    for line in result.stdout.split('\n'):
        if 'Number of entries' in line:
            old_count = int(line.split(':')[1].strip())
            break
    
    subprocess.run(['ipset', 'flush', 'GOVIPS'], check=False)
    count = 0
    for line in content.split('\n'):
        match = re.match(r'^add blacklist-v4 ([0-9./]+)', line)
        if match:
            subnet = match.group(1)
            subprocess.run(['ipset', 'add', 'GOVIPS', subnet], check=False, stderr=subprocess.DEVNULL)
            count += 1
    
    new_count = count
    print(f'OK: {new_count} entries (было: {old_count}, добавлено: {new_count - old_count})')
    
    # Сохраняем количество
    with open('/etc/rkn-watcher/gov_count.txt', 'w') as f:
        f.write(str(new_count))
        
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
" >> "$LOG_DIR/update.log" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] GOVIPS обновлён" >> "$LOG_DIR/update.log"
EOF

    # 5. update.sh
    cat > "$INSTALL_DIR/update.sh" << 'EOF'
#!/bin/bash
INSTALL_DIR="/opt/rkn-watcher"
LOG_DIR="/var/log/rkn-watcher"
mkdir -p "$LOG_DIR"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === ЗАПУСК ОБНОВЛЕНИЯ ===" >> "$LOG_DIR/update.log"

# Обновление TSPUBLOCK
if [ -f "$INSTALL_DIR/update_tspublock.sh" ]; then
    "$INSTALL_DIR/update_tspublock.sh"
else
    echo "ОШИБКА: update_tspublock.sh не найден" >> "$LOG_DIR/update.log"
fi

# Обновление GOVIPS
if [ -f "$INSTALL_DIR/update_govips.sh" ]; then
    "$INSTALL_DIR/update_govips.sh"
else
    echo "ОШИБКА: update_govips.sh не найден" >> "$LOG_DIR/update.log"
fi

# Обновление правил iptables после обновления списков
if [ -f /etc/rkn-watcher/settings.conf ]; then
    LOG_ENABLE=$(grep LOG_ENABLE /etc/rkn-watcher/settings.conf | cut -d'"' -f2)
else
    LOG_ENABLE="n"
fi

iptables -F TSPUBLOCK 2>/dev/null
iptables -A TSPUBLOCK -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j DROP
if [[ "$LOG_ENABLE" == "y" ]]; then
    iptables -I TSPUBLOCK 1 -p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j LOG --log-prefix "TSPUBLOCK: " --log-level 4
fi

iptables -F GOVBLOCK 2>/dev/null
iptables -A GOVBLOCK -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j DROP
if [[ "$LOG_ENABLE" == "y" ]]; then
    iptables -I GOVBLOCK 1 -p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j LOG --log-prefix "GOVBLOCK: " --log-level 4
fi

# Сохранение правил
ipset save > /etc/ipset.conf
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    iptables-save > /etc/iptables/rules.v4
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === ОБНОВЛЕНИЕ ЗАВЕРШЕНО ===" >> "$LOG_DIR/update.log"
EOF

    chmod +x "$INSTALL_DIR/geoip_firewall.py"
    chmod +x "$INSTALL_DIR/rkn-watcher-daemon.py"
    chmod +x "$INSTALL_DIR/update_tspublock.sh"
    chmod +x "$INSTALL_DIR/update_govips.sh"
    chmod +x "$INSTALL_DIR/update.sh"
    
    success "Все 5 скриптов созданы"
}

# ==================== ФУНКЦИИ УПРАВЛЕНИЯ СИМЛИНКОМ ====================

# Создание команды rkn-watcher
create_command() {
    info "Создание команды rkn-watcher..."
    
    # Удаляем старые файлы
    rm -f /usr/bin/rkn-watcher
    rm -f /usr/local/bin/rkn-watcher
    
    # Копируем текущий скрипт в /usr/local/bin/rkn-watcher
    cp "$0" "$SYMLINK_PATH"
    chmod +x "$SYMLINK_PATH"
    
    # Создаём ссылку в /usr/bin
    ln -sf "$SYMLINK_PATH" /usr/bin/rkn-watcher
    
    success "Команда создана: $SYMLINK_PATH"
    success "Также доступна как: /usr/bin/rkn-watcher"
}

# Удаление команды
remove_command() {
    info "Удаление команды rkn-watcher..."
    rm -f "$SYMLINK_PATH"
    rm -f /usr/bin/rkn-watcher
    success "Команда rkn-watcher удалена"
}

# ==================== ФУНКЦИИ НАСТРОЙКИ ====================

# Сохранение настроек
save_settings() {
    local filter_ports=$1
    local log_enable=$2
    local setup_ufw=$3
    local auto_update=$4
    
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
# RKN Watcher Configuration
FILTER_PORTS="$filter_ports"
LOG_ENABLE="$log_enable"
UFW_INTEGRATION="$setup_ufw"
AUTO_UPDATE="$auto_update"
VENV_PATH="$VENV_DIR"
INSTALL_DATE="$(date)"
LAST_UPDATE="$(date)"
TSPU_COUNT="$(cat $CONFIG_DIR/tspu_count.txt 2>/dev/null || echo "0")"
GOV_COUNT="$(cat $CONFIG_DIR/gov_count.txt 2>/dev/null || echo "0")"
EOF
    success "Настройки сохранены в $CONFIG_FILE"
}

# Настройка systemd сервиса
setup_services() {
    info "Настройка systemd сервиса..."
    
    cat > /etc/systemd/system/rkn-watcher.service << EOF
[Unit]
Description=RKN Watcher Daemon - GeoIP Firewall
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$VENV_DIR/bin/python3 $INSTALL_DIR/rkn-watcher-daemon.py
Restart=always
RestartSec=10
User=root
WorkingDirectory=$INSTALL_DIR
StandardOutput=journal
StandardError=journal

# Security
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/etc/rkn-watcher /var/log/rkn-watcher /var/run

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable rkn-watcher
    systemctl start rkn-watcher
    
    # Скрипт восстановления
    cat > /etc/network/if-pre-up.d/iptables_restore << 'EOF'
#!/bin/bash
# Восстановление ipset
if [ -f /etc/ipset.conf ]; then
    ipset restore < /etc/ipset.conf 2>/dev/null
fi

# Создание цепочек
iptables -N TSPUBLOCK 2>/dev/null
iptables -N GOVBLOCK 2>/dev/null
iptables -N GEOIP_DROP 2>/dev/null

# Восстановление iptables
if [ -f /etc/iptables/rules.v4 ]; then
    iptables-restore < /etc/iptables/rules.v4 2>/dev/null
fi

# Добавление прыжков
iptables -C INPUT -j TSPUBLOCK 2>/dev/null || iptables -I INPUT 1 -j TSPUBLOCK
iptables -C INPUT -j GOVBLOCK 2>/dev/null || iptables -I INPUT 2 -j GOVBLOCK
EOF
    chmod +x /etc/network/if-pre-up.d/iptables_restore
    
    success "Сервис настроен"
}

# ==================== ФУНКЦИИ УПРАВЛЕНИЯ БЕЛЫМ СПИСКОМ ====================

# Добавить страну
add_country() {
    echo "Коды стран (например, RU, US, DE, GB):"
    echo "RU - Россия, US - США, DE - Германия, GB - Великобритания"
    echo "FR - Франция, IT - Италия, ES - Испания, NL - Нидерланды"
    echo "PL - Польша, UA - Украина, KZ - Казахстан, BY - Беларусь"
    echo "0) Назад"
    read -p "Введите код страны: " country
    
    if [[ "$country" == "0" ]]; then
        return
    fi
    
    country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
    
    "$VENV_DIR/bin/python3" -c "
import json
with open('$WHITELIST_FILE', 'r') as f:
    data = json.load(f)
if '$country' not in data['countries']:
    data['countries'].append('$country')
    with open('$WHITELIST_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print('OK')
else:
    print('EXISTS')
"
    
    if [[ $? -eq 0 ]]; then
        success "Страна $country добавлена"
        "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
    else
        warn "Страна уже в списке"
    fi
    sleep 2
}

# Удалить страну
remove_country() {
    show_countries
    read -p "Введите код страны для удаления: " country
    
    if [[ "$country" == "0" ]]; then
        return
    fi
    
    country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
    
    "$VENV_DIR/bin/python3" -c "
import json
with open('$WHITELIST_FILE', 'r') as f:
    data = json.load(f)
if '$country' in data['countries']:
    data['countries'].remove('$country')
    with open('$WHITELIST_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print('OK')
else:
    print('NOTFOUND')
"
    
    if [[ $? -eq 0 ]]; then
        success "Страна $country удалена"
        "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
    else
        warn "Страна не найдена"
    fi
    sleep 2
}

# Показать страны
show_countries() {
    clear
    title
    echo -e "${CYAN}              БЕЛЫЙ СПИСОК СТРАН${NC}"
    title
    echo ""
    "$VENV_DIR/bin/python3" -c "import json; data=json.load(open('$WHITELIST_FILE')); print('\n'.join(data['countries']) if data['countries'] else 'Пусто')"
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Добавить IP в белый список
add_ip_whitelist() {
    read -p "Введите IP или подсеть (например, 192.168.1.1 или 10.0.0.0/24): " ip
    
    if [[ "$ip" == "0" ]]; then
        return
    fi
    
    "$VENV_DIR/bin/python3" -c "
import json
with open('$WHITELIST_FILE', 'r') as f:
    data = json.load(f)
if '$ip' not in data['ips']:
    data['ips'].append('$ip')
    with open('$WHITELIST_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print('OK')
else:
    print('EXISTS')
"
    
    if [[ $? -eq 0 ]]; then
        success "IP $ip добавлен в белый список"
        "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
    else
        warn "IP уже в списке"
    fi
    sleep 2
}

# Удалить IP из белого списка
remove_ip_whitelist() {
    show_whitelist_full
    read -p "Введите IP для удаления: " ip
    
    if [[ "$ip" == "0" ]]; then
        return
    fi
    
    "$VENV_DIR/bin/python3" -c "
import json
with open('$WHITELIST_FILE', 'r') as f:
    data = json.load(f)
if '$ip' in data['ips']:
    data['ips'].remove('$ip')
    with open('$WHITELIST_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print('OK')
else:
    print('NOTFOUND')
"
    
    if [[ $? -eq 0 ]]; then
        success "IP $ip удалён из белого списка"
        "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
    else
        warn "IP не найден"
    fi
    sleep 2
}

# Добавить порт в белый список
add_port_whitelist() {
    read -p "Введите порт: " port
    
    if [[ "$port" == "0" ]]; then
        return
    fi
    
    "$VENV_DIR/bin/python3" -c "
import json
with open('$WHITELIST_FILE', 'r') as f:
    data = json.load(f)
if $port not in data['ports']:
    data['ports'].append($port)
    with open('$WHITELIST_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print('OK')
else:
    print('EXISTS')
"
    
    if [[ $? -eq 0 ]]; then
        success "Порт $port добавлен в белый список"
        "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
    else
        warn "Порт уже в списке"
    fi
    sleep 2
}

# Удалить порт из белого списка
remove_port_whitelist() {
    show_whitelist_full
    read -p "Введите порт для удаления: " port
    
    if [[ "$port" == "0" ]]; then
        return
    fi
    
    "$VENV_DIR/bin/python3" -c "
import json
with open('$WHITELIST_FILE', 'r') as f:
    data = json.load(f)
if $port in data['ports']:
    data['ports'].remove($port)
    with open('$WHITELIST_FILE', 'w') as f:
        json.dump(data, f, indent=4)
    print('OK')
else:
    print('NOTFOUND')
"
    
    if [[ $? -eq 0 ]]; then
        success "Порт $port удалён из белого списка"
        "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
    else
        warn "Порт не найден"
    fi
    sleep 2
}

# Показать полный белый список
show_whitelist_full() {
    clear
    title
    echo -e "${CYAN}              ПОЛНЫЙ БЕЛЫЙ СПИСОК${NC}"
    title
    echo ""
    echo "=== Страны ==="
    "$VENV_DIR/bin/python3" -c "import json; data=json.load(open('$WHITELIST_FILE')); print('\n'.join(data['countries']) if data['countries'] else 'Пусто')"
    echo ""
    echo "=== IP адреса и подсети ==="
    "$VENV_DIR/bin/python3" -c "import json; data=json.load(open('$WHITELIST_FILE')); print('\n'.join(data['ips']) if data['ips'] else 'Пусто')"
    echo ""
    echo "=== Порты ==="
    "$VENV_DIR/bin/python3" -c "import json; data=json.load(open('$WHITELIST_FILE')); print('\n'.join(map(str, data['ports'])) if data['ports'] else 'Пусто')"
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Включить/отключить GeoIP фильтрацию
toggle_geoip() {
    current=$("$VENV_DIR/bin/python3" -c "import json; print(json.load(open('$WHITELIST_FILE'))['enabled'])")
    if [[ "$current" == "True" ]]; then
        "$VENV_DIR/bin/python3" -c "import json; d=json.load(open('$WHITELIST_FILE')); d['enabled']=False; json.dump(d, open('$WHITELIST_FILE','w'))"
        success "GeoIP фильтрация ОТКЛЮЧЕНА"
    else
        "$VENV_DIR/bin/python3" -c "import json; d=json.load(open('$WHITELIST_FILE')); d['enabled']=True; json.dump(d, open('$WHITELIST_FILE','w'))"
        success "GeoIP фильтрация ВКЛЮЧЕНА"
    fi
    "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
    sleep 2
}

# ==================== ФУНКЦИИ СТАТИСТИКИ И ЛОГОВ ====================

# Показать статистику блокировок
show_block_stats() {
    clear
    title
    echo -e "${CYAN}              СТАТИСТИКА БЛОКИРОВОК${NC}"
    title
    echo ""
    
    echo -e "${GREEN}=== TSPUBLOCK (CyberOK Skipa) ===${NC}"
    iptables -L TSPUBLOCK -v -n 2>/dev/null | grep -v "Chain" | head -5
    echo ""
    echo -e "${GREEN}=== GOVIPS (Госорганы РФ) ===${NC}"
    iptables -L GOVBLOCK -v -n 2>/dev/null | grep -v "Chain" | head -5
    echo ""
    echo -e "${GREEN}=== GEOIP_DROP ===${NC}"
    iptables -L GEOIP_DROP -v -n 2>/dev/null | grep -v "Chain" | head -10
    echo ""
    echo -e "${GREEN}=== Размеры списков ===${NC}"
    tspu_count=$(ipset list TSPUIPS 2>/dev/null | grep 'Number of entries' | awk '{print $NF}' || echo "0")
    gov_count=$(ipset list GOVIPS 2>/dev/null | grep 'Number of entries' | awk '{print $NF}' || echo "0")
    echo "  TSPUIPS: $tspu_count подсетей"
    echo "  GOVIPS: $gov_count подсетей"
    echo ""
    
    if [[ -f "$CONFIG_DIR/tspu_count.txt" ]]; then
        echo "Последнее обновление TSPUBLOCK: $(cat $CONFIG_DIR/tspu_count.txt 2>/dev/null) записей"
    fi
    if [[ -f "$CONFIG_DIR/gov_count.txt" ]]; then
        echo "Последнее обновление GOVIPS: $(cat $CONFIG_DIR/gov_count.txt 2>/dev/null) записей"
    fi
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
    
    echo -e "${GREEN}=== TSPUBLOCK ===${NC}"
    iptables -L TSPUBLOCK -v -n 2>/dev/null | head -15
    echo ""
    echo -e "${GREEN}=== GOVBLOCK ===${NC}"
    iptables -L GOVBLOCK -v -n 2>/dev/null | head -15
    echo ""
    echo -e "${GREEN}=== GEOIP_DROP ===${NC}"
    iptables -L GEOIP_DROP -v -n 2>/dev/null | head -15
    echo ""
    echo -e "${GREEN}=== Цепочки INPUT ===${NC}"
    iptables -L INPUT -v -n 2>/dev/null | head -20
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Показать логи
show_logs() {
    while true; do
        clear
        title
        echo -e "${CYAN}              ЛОГИ${NC}"
        title
        echo ""
        echo "1) Логи обновлений"
        echo "2) Логи GeoIP фильтрации"
        echo "3) Логи Watcher сервиса"
        echo "4) Системные логи блокировок (kern.log)"
        echo "5) Очистить все логи"
        echo "0) Назад"
        echo ""
        read -p "Выберите пункт: " choice
        
        case $choice in
            1)
                if [[ -f "$LOG_DIR/update.log" ]]; then
                    tail -50 "$LOG_DIR/update.log"
                else
                    echo "Логи не найдены"
                fi
                echo ""
                read -p "Нажмите Enter..."
                ;;
            2)
                if [[ -f "$LOG_DIR/geoip.log" ]]; then
                    tail -50 "$LOG_DIR/geoip.log"
                else
                    echo "Логи не найдены"
                fi
                echo ""
                read -p "Нажмите Enter..."
                ;;
            3)
                if [[ -f "$LOG_DIR/watcher.log" ]]; then
                    tail -50 "$LOG_DIR/watcher.log"
                else
                    echo "Логи не найдены"
                fi
                echo ""
                read -p "Нажмите Enter..."
                ;;
            4)
                if [[ -f /var/log/kern.log ]]; then
                    echo "=== TSPUBLOCK блокировки ==="
                    grep "TSPUBLOCK:" /var/log/kern.log 2>/dev/null | tail -20
                    echo ""
                    echo "=== GOVBLOCK блокировки ==="
                    grep "GOVBLOCK:" /var/log/kern.log 2>/dev/null | tail -20
                else
                    echo "Лог-файл /var/log/kern.log не найден"
                fi
                echo ""
                read -p "Нажмите Enter..."
                ;;
            5)
                read -p "Очистить все логи? (y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    > "$LOG_DIR/update.log" 2>/dev/null
                    > "$LOG_DIR/geoip.log" 2>/dev/null
                    > "$LOG_DIR/watcher.log" 2>/dev/null
                    > /var/log/kern.log 2>/dev/null
                    success "Логи очищены"
                fi
                sleep 2
                ;;
            0) break ;;
            *) error "Неверный выбор"; sleep 2 ;;
        esac
    done
}

# ==================== ФУНКЦИИ НАСТРОЙКИ UFW ====================

# Интеграция с UFW
integrate_ufw() {
    if ! check_ufw; then
        error "UFW не установлен"
        return
    fi
    
    info "Интеграция правил RKN Watcher в UFW..."
    
    if [[ -f "$UFW_BEFORE_FILE" ]]; then
        cp "$UFW_BEFORE_FILE" "${UFW_BEFORE_FILE}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
    fi
    
    sed -i '/# === RKN WATCHER START ===/,/# === RKN WATCHER END ===/d' "$UFW_BEFORE_FILE" 2>/dev/null
    
    cat >> "$UFW_BEFORE_FILE" << 'EOF'

# === RKN WATCHER START ===
# Создание цепочек
*filter
-I INPUT 1 -j TSPUBLOCK
-I INPUT 2 -j GOVBLOCK
# === RKN WATCHER END ===
EOF
    
    ensure_chains
    
    ufw disable 2>/dev/null || true
    sleep 1
    ufw enable 2>/dev/null || true
    
    success "UFW интеграция завершена"
    sleep 2
}

# Удалить интеграцию с UFW
remove_ufw_integration() {
    if [[ -f "$UFW_BEFORE_FILE" ]]; then
        sed -i '/# === RKN WATCHER START ===/,/# === RKN WATCHER END ===/d' "$UFW_BEFORE_FILE" 2>/dev/null
        success "Интеграция удалена из UFW"
        
        ufw disable 2>/dev/null || true
        ufw enable 2>/dev/null || true
    else
        warn "Файл UFW не найден"
    fi
    sleep 2
}

# Настройка базовых правил UFW
configure_basic_ufw() {
    info "Настройка базовых правил UFW..."
    
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    
    read -p "Какой порт SSH? (по умолчанию 22): " ssh_port
    ssh_port=${ssh_port:-22}
    ufw allow "$ssh_port"/tcp comment 'SSH'
    
    read -p "Разрешить HTTP (80)? (y/n): " allow_http
    if [[ "$allow_http" == "y" ]]; then
        ufw allow 80/tcp comment 'HTTP'
    fi
    
    read -p "Разрешить HTTPS (443)? (y/n): " allow_https
    if [[ "$allow_https" == "y" ]]; then
        ufw allow 443/tcp comment 'HTTPS'
    fi
    
    ufw --force enable
    
    success "Базовые правила UFW настроены"
    ufw status verbose
    sleep 3
}

# Добавить правило UFW
add_ufw_rule() {
    echo "Тип правила:"
    echo "1) Разрешить порт (TCP)"
    echo "2) Разрешить порт (UDP)"
    echo "3) Разрешить IP адрес"
    echo "4) Заблокировать IP адрес"
    echo "5) Разрешить подсеть"
    echo "0) Назад"
    read -p "Выберите: " rule_type
    
    case $rule_type in
        1)
            read -p "Введите порт: " port
            read -p "Комментарий: " comment
            ufw allow "$port"/tcp comment "$comment"
            success "Порт $port разрешён"
            ;;
        2)
            read -p "Введите порт: " port
            read -p "Комментарий: " comment
            ufw allow "$port"/udp comment "$comment"
            success "Порт $port разрешён"
            ;;
        3)
            read -p "Введите IP адрес: " ip
            read -p "Комментарий: " comment
            ufw allow from "$ip" comment "$comment"
            success "IP $ip разрешён"
            ;;
        4)
            read -p "Введите IP адрес: " ip
            read -p "Комментарий: " comment
            ufw deny from "$ip" comment "$comment"
            success "IP $ip заблокирован"
            ;;
        5)
            read -p "Введите подсеть (например, 192.168.1.0/24): " subnet
            read -p "Комментарий: " comment
            ufw allow from "$subnet" comment "$comment"
            success "Подсеть $subnet разрешена"
            ;;
        0) return ;;
        *) error "Неверный выбор" ;;
    esac
    sleep 2
}

# Удалить правило UFW
remove_ufw_rule() {
    echo "Текущие правила UFW:"
    ufw status numbered
    echo ""
    echo "0) Назад"
    read -p "Введите номер правила для удаления: " rule_num
    if [[ "$rule_num" == "0" ]]; then
        return
    fi
    echo "y" | ufw delete "$rule_num"
    success "Правило удалено"
    sleep 2
}

# Показать статус UFW
show_ufw_status() {
    clear
    title
    echo -e "${CYAN}              СТАТУС UFW${NC}"
    title
    echo ""
    ufw status verbose
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

# Включить/выключить UFW
toggle_ufw() {
    if ufw status | grep -q "active"; then
        ufw disable
        success "UFW выключен"
    else
        ufw --force enable
        success "UFW включён"
    fi
    sleep 2
}

# ==================== ФУНКЦИИ НАСТРОЙКИ РАСПИСАНИЯ ====================

# Настройка расписания
schedule_menu() {
    while true; do
        clear
        title
        echo -e "${CYAN}              НАСТРОЙКА РАСПИСАНИЯ${NC}"
        title
        echo ""
        
        current=$(crontab -l 2>/dev/null | grep "$INSTALL_DIR/update.sh" | head -1 | awk '{print $1,$2,$3,$4,$5}')
        [[ -z "$current" ]] && current="не настроено"
        
        echo "1) Показать текущие задания"
        echo "2) Изменить время обновления (сейчас: $current)"
        echo "3) Включить/отключить автообновление"
        echo "4) Добавить дополнительное задание"
        echo "5) Удалить все задания"
        echo "0) Назад"
        echo ""
        read -p "Выберите пункт: " choice
        
        case $choice in
            1)
                echo ""
                echo "=== Текущие задания cron ==="
                crontab -l 2>/dev/null | grep -E "update_|rkn" || echo "Нет заданий"
                echo ""
                read -p "Нажмите Enter..."
                ;;
            2)
                echo "Формат: минуты часы день месяц день_недели"
                echo "Примеры:"
                echo "  0 3 * * *     - ежедневно в 3:00"
                echo "  */30 * * * *  - каждые 30 минут"
                echo "  0 3,15 * * *  - в 3:00 и 15:00"
                echo "  0 3 * * 1     - каждый понедельник в 3:00"
                read -p "Введите новое расписание: " new_schedule
                crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/update.sh" | crontab - 2>/dev/null
                (crontab -l 2>/dev/null; echo "$new_schedule $INSTALL_DIR/update.sh") | crontab -
                success "Расписание обновлено"
                sleep 2
                ;;
            3)
                if crontab -l 2>/dev/null | grep -q "$INSTALL_DIR/update.sh"; then
                    crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/update.sh" | crontab - 2>/dev/null
                    success "Автообновление ОТКЛЮЧЕНО"
                    if [[ -f "$CONFIG_FILE" ]]; then
                        sed -i 's/AUTO_UPDATE=.*/AUTO_UPDATE="n"/' "$CONFIG_FILE"
                    fi
                else
                    (crontab -l 2>/dev/null; echo "0 3 * * * $INSTALL_DIR/update.sh") | crontab -
                    success "Автообновление ВКЛЮЧЕНО (ежедневно в 3:00)"
                    if [[ -f "$CONFIG_FILE" ]]; then
                        sed -i 's/AUTO_UPDATE=.*/AUTO_UPDATE="y"/' "$CONFIG_FILE"
                    fi
                fi
                sleep 2
                ;;
            4)
                echo "Формат: минуты часы день месяц день_недели команда"
                echo "Пример: 0 */6 * * * /opt/rkn-watcher/update.sh"
                read -p "Введите задание: " new_job
                (crontab -l 2>/dev/null; echo "$new_job") | crontab -
                success "Задание добавлено"
                sleep 2
                ;;
            5)
                read -p "Удалить все задания RKN Watcher? (y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/update.sh" | crontab - 2>/dev/null
                    success "Все задания удалены"
                fi
                sleep 2
                ;;
            0) break ;;
            *) error "Неверный выбор"; sleep 2 ;;
        esac
    done
}

# ==================== ФУНКЦИИ УПРАВЛЕНИЯ ====================

# Меню управления блокировками
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
        echo "4) Изменить порты для GeoIP фильтрации"
        echo "5) Показать текущие правила iptables"
        echo "6) Показать статистику блокировок"
        echo "0) Назад"
        echo ""
        read -p "Выберите пункт: " choice
        
        case $choice in
            1) toggle_tspublock ;;
            2) toggle_govips ;;
            3) toggle_geoip ;;
            4) change_geoip_ports ;;
            5) show_iptables_rules ;;
            6) show_block_stats ;;
            0) break ;;
            *) error "Неверный выбор"; sleep 2 ;;
        esac
    done
}

# Изменение портов GeoIP
change_geoip_ports() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error "Файл конфигурации не найден"
        return
    fi
    
    current=$(grep "^FILTER_PORTS=" "$CONFIG_FILE" | cut -d'"' -f2)
    echo "Текущие порты: $current"
    echo ""
    echo "1) Фильтрация на конкретном порту"
    echo "2) Фильтрация на нескольких портах"
    echo "3) Фильтрация для всех портов"
    echo "0) Назад"
    read -p "Выберите вариант: " port_choice
    
    case $port_choice in
        1)
            read -p "Введите порт: " new_ports
            ;;
        2)
            read -p "Введите порты через запятую: " new_ports
            ;;
        3)
            new_ports="all"
            ;;
        0) return ;;
        *) return ;;
    esac
    
    sed -i "s/FILTER_PORTS=.*/FILTER_PORTS=\"$new_ports\"/" "$CONFIG_FILE"
    "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
    success "Порты изменены"
    sleep 2
}

# Меню GeoIP
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
            1) add_country ;;
            2) remove_country ;;
            3) show_countries ;;
            4) add_ip_whitelist ;;
            5) remove_ip_whitelist ;;
            6) add_port_whitelist ;;
            7) remove_port_whitelist ;;
            8) show_whitelist_full ;;
            9) toggle_geoip ;;
            0) break ;;
            *) error "Неверный выбор"; sleep 2 ;;
        esac
    done
}

# Меню UFW
ufw_config_menu() {
    while true; do
        clear
        title
        echo -e "${CYAN}              НАСТРОЙКА UFW${NC}"
        title
        echo ""
        
        if ! check_ufw; then
            echo -e "${YELLOW}UFW не установлен. Установить?${NC}"
            echo "1) Установить UFW"
            echo "0) Назад"
            read -p "Выберите: " choice
            if [[ $choice == "1" ]]; then
                apt install -y ufw
                success "UFW установлен"
            else
                break
            fi
        fi
        
        echo "1) Интегрировать правила RKN Watcher в UFW"
        echo "2) Настроить базовые правила UFW (SSH, порты)"
        echo "3) Добавить правило UFW"
        echo "4) Удалить правило UFW"
        echo "5) Показать статус UFW"
        echo "6) Включить/выключить UFW"
        echo "7) Удалить интеграцию RKN Watcher из UFW"
        echo "0) Назад"
        echo ""
        read -p "Выберите пункт: " choice
        
        case $choice in
            1) integrate_ufw ;;
            2) configure_basic_ufw ;;
            3) add_ufw_rule ;;
            4) remove_ufw_rule ;;
            5) show_ufw_status ;;
            6) toggle_ufw ;;
            7) remove_ufw_integration ;;
            0) break ;;
            *) error "Неверный выбор"; sleep 2 ;;
        esac
    done
}

# ==================== ОСНОВНЫЕ ФУНКЦИИ ====================

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
        echo "4) Запустить полное обновление (с применением правил)"
        echo "0) Назад"
        echo ""
        read -p "Выберите: " choice
        
        # Получаем настройку логирования из конфига
        local log_enable="n"
        if [[ -f "$CONFIG_FILE" ]]; then
            log_enable=$(grep "^LOG_ENABLE=" "$CONFIG_FILE" | cut -d'"' -f2)
            [[ -z "$log_enable" ]] && log_enable="n"
        fi
        
        case $choice in
            1)
                info "Обновление TSPUBLOCK..."
                if download_tspublock_list; then
                    setup_tspublock_rules "$log_enable"
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
                    setup_govips_rules "$log_enable"
                    save_rules
                    success "GOVIPS успешно обновлён"
                else
                    error "Ошибка при обновлении GOVIPS"
                fi
                sleep 2
                ;;
            3)
                info "Обновление TSPUBLOCK и GOVIPS..."
                local tspu_ok=false
                local gov_ok=false
                
                if download_tspublock_list; then
                    tspu_ok=true
                fi
                if download_govips_list; then
                    gov_ok=true
                fi
                
                if $tspu_ok; then
                    setup_tspublock_rules "$log_enable"
                fi
                if $gov_ok; then
                    setup_govips_rules "$log_enable"
                fi
                
                if $tspu_ok && $gov_ok; then
                    save_rules
                    success "Оба списка успешно обновлены"
                elif $tspu_ok; then
                    save_rules
                    warn "TSPUBLOCK обновлён, GOVIPS - ошибка"
                elif $gov_ok; then
                    save_rules
                    warn "GOVIPS обновлён, TSPUBLOCK - ошибка"
                else
                    error "Ошибка при обновлении обоих списков"
                fi
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
    apt update -qq 2>/dev/null
    apt install -y -qq iptables ipset curl python3 python3-venv python3-pip cron 2>/dev/null
    
    # Устанавливаем netfilter-persistent без конфликта с ufw
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
        apt install -y -qq ufw 2>/dev/null
        success "UFW установлен"
    fi
    
    # Создание директорий
    info "Создание директорий..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p /etc/iptables
    
    # Копируем текущий скрипт в /opt/rkn-watcher/
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
    python3 -m venv "$VENV_DIR" 2>/dev/null
    "$VENV_DIR/bin/pip" install --upgrade pip -q 2>/dev/null
    "$VENV_DIR/bin/pip" install requests urllib3 -q 2>/dev/null
    success "Виртуальное окружение создано"
    
    # СОЗДАНИЕ ВСЕХ СКРИПТОВ
    create_all_scripts
    
    # Создание цепочек iptables
    ensure_chains
    
    # Загрузка списков
    echo ""
    download_tspublock_list
    download_govips_list
    
    # Настройка правил
    setup_tspublock_rules "$log_enable"
    setup_govips_rules "$log_enable"
    
    # Применение GeoIP правил
    "$VENV_DIR/bin/python3" "$INSTALL_DIR/geoip_firewall.py" apply
    
    # Сохранение настроек
    save_settings "$filter_ports" "$log_enable" "$setup_ufw" "$auto_update"
    
    # Настройка сервисов
    setup_services
    
    # СОЗДАНИЕ КОМАНДЫ (СИМЛИНКА)
    create_command
    
    # Сохранение правил
    save_rules
    
    # Настройка cron
    if [[ "$auto_update" == "y" ]]; then
        info "Настройка cron..."
        (crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/update.sh"; echo "0 3 * * * $INSTALL_DIR/update.sh") | crontab -
        success "Cron настроен (ежедневно в 3:00)"
    fi
    
    # Интеграция с UFW если нужно
    if [[ "$setup_ufw" == "y" ]]; then
        integrate_ufw
        configure_basic_ufw
    fi
    
    success "УСТАНОВКА ЗАВЕРШЕНА!"
    
    # Показ статистики
    tspu_count=$(ipset list TSPUIPS 2>/dev/null | grep 'Number of entries' | awk '{print $NF}' || echo "0")
    gov_count=$(ipset list GOVIPS 2>/dev/null | grep 'Number of entries' | awk '{print $NF}' || echo "0")
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "${GREEN}                    УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo -e "${CYAN}📊 ЗАГРУЖЕННЫЕ СПИСКИ:${NC}"
    echo "  • TSPUBLOCK: $tspu_count подсетей"
    echo "  • GOVIPS: $gov_count подсетей"
    echo ""
    echo -e "${CYAN}📁 УСТАНОВЛЕННЫЕ КОМПОНЕНТЫ:${NC}"
    echo "  • Скрипты: $INSTALL_DIR/"
    echo "  • Конфигурация: $CONFIG_DIR/"
    echo "  • Логи: $LOG_DIR/"
    echo "  • Сервис: rkn-watcher.service"
    echo ""
    echo -e "${CYAN}🚀 КАК ЗАПУСКАТЬ ПРОГРАММУ:${NC}"
    echo "  sudo rkn-watcher"
    echo ""
    echo -e "${CYAN}📋 ДОСТУПНЫЕ КОМАНДЫ:${NC}"
    echo "  sudo rkn-watcher                    - Запуск главного меню"
    echo "  sudo systemctl status rkn-watcher   - Проверка статуса демона"
    echo "  sudo systemctl restart rkn-watcher  - Перезапуск демона"
    echo "  sudo systemctl stop rkn-watcher     - Остановка демона"
    echo "  sudo systemctl start rkn-watcher    - Запуск демона"
    echo ""
    echo -e "${CYAN}📂 ЛОГИ:${NC}"
    echo "  tail -f $LOG_DIR/update.log    - Логи обновлений"
    echo "  tail -f $LOG_DIR/geoip.log     - Логи GeoIP"
    echo "  tail -f $LOG_DIR/watcher.log   - Логи демона"
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
    
    echo "Выберите тип удаления:"
    echo ""
    echo "1) ЧАСТИЧНОЕ УДАЛЕНИЕ (сохраняется основной скрипт и симлинк)"
    echo "   - Удаляются все правила iptables и ipset"
    echo "   - Удаляется виртуальное окружение"
    echo "   - Удаляются конфигурация и логи"
    echo "   - Удаляется сервис и задания cron"
    echo "   - Удаляются 5 вспомогательных скриптов"
    echo "   - ОСТАЁТСЯ: /opt/rkn-watcher/rkn-watcher.sh и команда rkn-watcher"
    echo ""
    echo "2) ПОЛНОЕ УДАЛЕНИЕ (удаляется всё)"
    echo "   - Удаляются все правила iptables и ipset"
    echo "   - Удаляется виртуальное окружение"
    echo "   - Удаляются конфигурация и логи"
    echo "   - Удаляется сервис и задания cron"
    echo "   - Удаляются ВСЕ скрипты (включая основной)"
    echo "   - Удаляется симлинк rkn-watcher"
    echo "   - Удаляется директория /opt/rkn-watcher"
    echo ""
    echo "0) Назад"
    echo ""
    read -p "Выберите тип удаления (1, 2 или 0): " delete_type
    
    if [[ "$delete_type" == "0" ]]; then
        return
    fi
    
    if [[ "$delete_type" != "1" && "$delete_type" != "2" ]]; then
        error "Неверный выбор"
        sleep 2
        return
    fi
    
    echo ""
    if [[ "$delete_type" == "1" ]]; then
        echo -e "${YELLOW}ВЫ ВЫБРАЛИ ЧАСТИЧНОЕ УДАЛЕНИЕ${NC}"
        echo -e "${YELLOW}Основной скрипт и симлинк будут сохранены${NC}"
    else
        echo -e "${RED}ВЫ ВЫБРАЛИ ПОЛНОЕ УДАЛЕНИЕ${NC}"
        echo -e "${RED}БУДЕТ УДАЛЕНО ВСЁ, включая основной скрипт и симлинк${NC}"
    fi
    echo ""
    read -p "Вы уверены? (напишите 'YES' для подтверждения): " confirm
    
    if [[ "$confirm" != "YES" ]]; then
        warn "Удаление отменено"
        sleep 2
        return
    fi
    
    if [[ "$delete_type" == "1" ]]; then
        info "Начинаю ЧАСТИЧНОЕ удаление RKN Watcher..."
    else
        info "Начинаю ПОЛНОЕ удаление RKN Watcher..."
    fi
    
    # 1. Остановка сервиса
    info "Остановка сервиса rkn-watcher..."
    systemctl stop rkn-watcher 2>/dev/null && success "Сервис остановлен" || warn "Сервис не был запущен"
    systemctl disable rkn-watcher 2>/dev/null && success "Сервис отключен" || true
    
    # 2. Удаление интеграции с UFW
    info "Удаление интеграции с UFW..."
    remove_ufw_integration
    
    # 3. Удаление прыжков из INPUT цепочки
    info "Удаление прыжков из INPUT цепочки..."
    iptables -D INPUT -j TSPUBLOCK 2>/dev/null && success "Прыжок TSPUBLOCK удалён" || warn "Прыжок TSPUBLOCK не найден"
    iptables -D INPUT -j GOVBLOCK 2>/dev/null && success "Прыжок GOVBLOCK удалён" || warn "Прыжок GOVBLOCK не найден"
    
    # 4. Очистка и удаление цепочек
    info "Очистка цепочек iptables..."
    iptables -F TSPUBLOCK 2>/dev/null && success "TSPUBLOCK очищен" || true
    iptables -F GOVBLOCK 2>/dev/null && success "GOVBLOCK очищен" || true
    iptables -F GEOIP_DROP 2>/dev/null && success "GEOIP_DROP очищен" || true
    
    iptables -X TSPUBLOCK 2>/dev/null && success "TSPUBLOCK удалён" || true
    iptables -X GOVBLOCK 2>/dev/null && success "GOVBLOCK удалён" || true
    iptables -X GEOIP_DROP 2>/dev/null && success "GEOIP_DROP удалён" || true
    
    # 5. Удаление ipset списков
    info "Удаление ipset списков..."
    ipset destroy TSPUIPS 2>/dev/null && success "TSPUIPS удалён" || warn "TSPUIPS не найден"
    ipset destroy GOVIPS 2>/dev/null && success "GOVIPS удалён" || warn "GOVIPS не найден"
    
    # 6. Удаление виртуального окружения
    info "Удаление виртуального окружения Python..."
    rm -rf "$VENV_DIR" && success "Виртуальное окружение удалено" || warn "Не удалось удалить venv"
    
    # 7. Удаление конфигурационных файлов
    info "Удаление конфигурационных файлов..."
    rm -rf "$CONFIG_DIR" && success "Удалена директория $CONFIG_DIR" || warn "Не удалось удалить $CONFIG_DIR"
    
    # 8. Удаление логов
    info "Удаление логов..."
    rm -rf "$LOG_DIR" && success "Удалена директория $LOG_DIR" || warn "Не удалось удалить $LOG_DIR"
    
    # 9. Удаление systemd сервиса
    info "Удаление systemd сервиса..."
    rm -f /etc/systemd/system/rkn-watcher.service && success "Файл сервиса удалён" || true
    systemctl daemon-reload && success "Systemd перезагружен" || true
    
    # 10. Удаление скрипта восстановления
    rm -f /etc/network/if-pre-up.d/iptables_restore && success "Скрипт восстановления удалён" || true
    
    # 11. Удаление файлов сохранённых правил
    info "Удаление сохранённых правил..."
    rm -f /etc/ipset.conf && success "ipset.conf удалён" || true
    rm -f /etc/iptables/rules.v4 && success "rules.v4 удалён" || true
    
    # 12. Удаление заданий cron
    info "Удаление заданий cron..."
    crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/update.sh" | crontab - 2>/dev/null && success "Задания cron удалены" || true
    
    # 13. УДАЛЕНИЕ 5 СОЗДАННЫХ СКРИПТОВ
    info "Удаление созданных скриптов..."
    rm -f "$INSTALL_DIR/geoip_firewall.py" && success "geoip_firewall.py удалён" || true
    rm -f "$INSTALL_DIR/rkn-watcher-daemon.py" && success "rkn-watcher-daemon.py удалён" || true
    rm -f "$INSTALL_DIR/update.sh" && success "update.sh удалён" || true
    rm -f "$INSTALL_DIR/update_tspublock.sh" && success "update_tspublock.sh удалён" || true
    rm -f "$INSTALL_DIR/update_govips.sh" && success "update_govips.sh удалён" || true
    
    # 14. ПОЛНОЕ УДАЛЕНИЕ (если выбран пункт 2)
    if [[ "$delete_type" == "2" ]]; then
        info "Выполнение полного удаления..."
        
        # Удаление симлинка
        info "Удаление симлинка rkn-watcher..."
        rm -f /usr/local/bin/rkn-watcher
        rm -f /usr/bin/rkn-watcher
        success "Симлинк удалён"
        
        # Удаление основного скрипта и директории
        info "Удаление основного скрипта..."
        rm -f "$INSTALL_DIR/rkn-watcher.sh"
        
        # Удаление директории
        rm -rf "$INSTALL_DIR"
        success "Директория $INSTALL_DIR удалена"
        
        success "ПОЛНОЕ УДАЛЕНИЕ ЗАВЕРШЕНО!"
        echo ""
        echo -e "${GREEN}✓ RKN Watcher полностью удалён из системы${NC}"
        echo ""
        
        read -p "Нажмите Enter для продолжения..."
        main_menu
        return
    fi
    
    # Сообщение для частичного удаления
    success "ЧАСТИЧНОЕ УДАЛЕНИЕ ЗАВЕРШЕНО!"
    echo ""
    echo -e "${GREEN}Сохранено:${NC}"
    echo "  • /opt/rkn-watcher/rkn-watcher.sh - основной скрипт"
    echo "  • /usr/local/bin/rkn-watcher - симлинк для запуска"
    echo ""
    echo -e "${YELLOW}Для ПОЛНОГО удаления (включая основной скрипт) выполните:${NC}"
    echo "  sudo rm -rf /opt/rkn-watcher"
    echo "  sudo rm -f /usr/local/bin/rkn-watcher /usr/bin/rkn-watcher"
    echo ""
    echo -e "${YELLOW}Или выберите пункт 2 'Полное удаление' при следующем запуске${NC}"
    echo ""
    
    read -p "Нажмите Enter для продолжения..."
    main_menu
}

# Переустановка
reinstall_menu() {
    uninstall_menu
    install_menu
}

# ==================== ГЛАВНОЕ МЕНЮ ====================

main_menu() {
    while true; do
        clear
        title
        echo -e "${CYAN}              RKN WATCHER - ЗАЩИТА ОТ ТСПУ И GEOIP${NC}"
        title
        echo ""
        
        if is_installed; then
            echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
            echo -e "${GREEN}                      РЕЖИМ УПРАВЛЕНИЯ${NC}"
            echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo "1) Управление блокировками (TSPUBLOCK + GOVIPS)"
            echo "2) Настройка GeoIP фильтрации"
            echo "3) Настройка UFW (интеграция)"
            echo "4) Настройка расписания обновлений"
            echo "5) Ручное обновление списков"
            echo "6) Просмотр статистики"
            echo "7) Просмотр логов"
            echo "8) Удаление (частичное или полное)"
            echo "9) Переустановка"
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
                3) ufw_config_menu ;;
                4) schedule_menu ;;
                5) manual_update ;;
                6) show_block_stats ;;
                7) show_logs ;;
                8) uninstall_menu ;;
                9) reinstall_menu ;;
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
