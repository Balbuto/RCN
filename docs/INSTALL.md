# Установка

## 1. Системные требования

Поддерживаемые системы:

- Debian 11 / 12
- Ubuntu 20.04 / 22.04 / 24.04

Минимальные требования:

- root-доступ;
- рабочий `systemd`;
- доступ в интернет для загрузки списков;
- пакеты `iptables`, `ipset`, `python3`, `curl` будут установлены автоматически.

## 2. Рекомендуемый способ установки

```bash
git clone https://github.com/<your-account>/RCN.git
cd RCN
chmod +x installer.sh rkn-watcher.sh
sudo ./installer.sh
```

Во время установки интерактивный `installer.sh`:

1. проверяет, что запуск выполнен от `root`;
2. проверяет наличие необходимых зависимостей;
3. устанавливает отсутствующие пакеты;
4. запускает основной интерактивный процесс установки `rkn-watcher.sh`.

Во время установки основной скрипт:

1. установит системные зависимости;
2. создаст каталоги в `/opt`, `/etc`, `/var/lib`, `/var/log`;
3. скопирует `rkn-watcher.sh`, `config_tool.py`, `geoip_apply.py` в `/opt/rkn-watcher`;
4. создаст команду `rkn-watcher` в `/usr/local/bin`;
5. создаст `systemd`-юниты:
   - `rkn-watcher-boot.service`
   - `rkn-watcher-update.service`
   - `rkn-watcher-update.timer`
6. загрузит `TSPUBLOCK` и `GOVIPS`;
7. применит firewall-правила.

## 3. Что создаётся на системе

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

## 4. Первый запуск

После установки можно открыть меню:

```bash
sudo rkn-watcher
```

Либо проверить статус из CLI:

```bash
sudo rkn-watcher status
```

## 5. Обновление до v3.1

Для установленной версии обновите рабочую копию, проверьте файлы релиза и запустите обновление через установщик:

```bash
cd RCN
git pull
sha256sum -c SHA256SUMS
sudo ./installer.sh install
```

При запросе выберите сохранение текущих настроек. Перед обновлением с v3.0.x удалите IPv6-записи из JSON GeoIP: v3.1 поддерживает только IPv4-записи.

## 6. Установка без git

Если по каким-то причинам нельзя использовать `git clone`, нужно скачать **все четыре файла**:

- `installer.sh`
- `rkn-watcher.sh`
- `config_tool.py`
- `geoip_apply.py`

И положить их в одну папку:

```bash
mkdir rcn
cd rcn
# скачать сюда четыре файла
chmod +x installer.sh rkn-watcher.sh
sudo ./installer.sh
```

Важно:
- `installer.sh` — рекомендуемая точка входа;
- запуск только одного `rkn-watcher.sh` без helper-файлов не поддерживается.

## 7. Удаление

```bash
sudo rkn-watcher uninstall
```

Или через меню.

Удаление:
- отключает таймер и boot-service;
- удаляет только управляемые цепочки и `ipset`;
- удаляет директории `/opt/rkn-watcher`, `/etc/rkn-watcher`, `/var/lib/rkn-watcher`, `/var/log/rkn-watcher`.

Глобальные системные файлы `iptables` и `ipset` целиком не удаляются.
