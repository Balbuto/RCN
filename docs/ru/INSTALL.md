# Установка

## Системные требования

Поддерживаемые системы:
- Debian 11 / 12
- Ubuntu 20.04 / 22.04 / 24.04

Требуется:
- root-доступ;
- `systemd`;
- доступ в интернет для первичной загрузки списков.

## Рекомендуемый способ

```bash
git clone https://github.com/Balbuto/RCN.git
cd RCN
chmod +x installer.sh rkn-watcher.sh
sudo ./installer.sh
```

Интерактивный `installer.sh`:
1. проверяет запуск от `root`;
2. проверяет наличие зависимостей;
3. устанавливает отсутствующие пакеты;
4. запускает основной интерактивный процесс установки `rkn-watcher.sh`.

Основной скрипт затем:
1. создаёт каталоги в `/opt`, `/etc`, `/var/lib`, `/var/log`;
2. копирует `rkn-watcher.sh`, `config_tool.py`, `geoip_apply.py` в `/opt/rkn-watcher`;
3. создаёт команду `rkn-watcher` в `/usr/local/bin`;
4. создаёт `systemd`-юниты для восстановления и автообновления;
5. загружает `TSPUBLOCK` и `GOVIPS`;
6. применяет правила `iptables` / `ipset`.

## Что создаётся на системе

### Исполняемые файлы
- `/opt/rkn-watcher/rkn-watcher.sh`
- `/opt/rkn-watcher/config_tool.py`
- `/opt/rkn-watcher/geoip_apply.py`
- `/usr/local/bin/rkn-watcher`

### Конфигурация
- `/etc/rkn-watcher/settings.conf`
- `/etc/rkn-watcher/whitelist.json`
- `/etc/rkn-watcher/blacklist.json`

### Состояние и кэш
- `/var/lib/rkn-watcher/cache/`
- `/var/lib/rkn-watcher/state/`
- `/var/lib/rkn-watcher/locks/`

### Логи
- `/var/log/rkn-watcher/update.log`
- `/var/log/rkn-watcher/actions.log`
- `/var/log/rkn-watcher/geoip.log`

## Первый запуск

```bash
sudo rkn-watcher
```

Или проверка статуса:

```bash
sudo rkn-watcher status
```

## Обновление установленной версии

```bash
cd RCN
# обновить файлы репозитория
sudo ./installer.sh install
```

## Установка без git

Нужно скачать в одну папку:
- `installer.sh`
- `rkn-watcher.sh`
- `config_tool.py`
- `geoip_apply.py`

Затем:

```bash
chmod +x installer.sh rkn-watcher.sh
sudo ./installer.sh
```

## Удаление

```bash
sudo ./installer.sh uninstall
```

Или:

```bash
sudo rkn-watcher uninstall
```

Удаляются только изменения, управляемые проектом.
