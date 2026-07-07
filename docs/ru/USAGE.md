# Использование

## Основные команды

### Через установщик
```bash
sudo ./installer.sh
sudo ./installer.sh install
sudo ./installer.sh uninstall
sudo ./installer.sh deps
sudo ./installer.sh status
```

### Через основной скрипт
```bash
sudo rkn-watcher install
sudo rkn-watcher update
sudo rkn-watcher apply
sudo rkn-watcher status
sudo rkn-watcher uninstall
sudo rkn-watcher --help
```

## Интерактивное меню

Запуск:

```bash
sudo rkn-watcher
```

Разделы меню:
- **Блок-листы** — включение/отключение `TSPUBLOCK` и `GOVIPS`, обновление списков, показ `iptables` / `ipset`;
- **GeoIP** — enable/disable, страны, allow/deny IP и порты;
- **Настройки** — `FILTER_PORTS`, `LOG_RST`, `AUTO_UPDATE`, пере-применение правил;
- **Статус**;
- **Логи**;
- **Переустановить / обновить**;
- **Удалить**.

## Обновление списков

Ручной запуск:

```bash
sudo rkn-watcher update
```

Плановый запуск:
- выполняется через `rkn-watcher-update.timer`;
- по умолчанию — ежедневно в `03:00`.

## Повторное применение правил

```bash
sudo rkn-watcher apply
```

## Просмотр логов

```bash
sudo tail -n 100 /var/log/rkn-watcher/update.log
sudo tail -n 100 /var/log/rkn-watcher/actions.log
sudo tail -n 100 /var/log/rkn-watcher/geoip.log
```

## Проверка таймера

```bash
systemctl status rkn-watcher-update.timer
systemctl list-timers | grep rkn-watcher
```

## Проверка правил и наборов

```bash
sudo iptables -L INPUT -v -n
sudo iptables -L TSPUBLOCK -v -n
sudo iptables -L GOVBLOCK -v -n
sudo iptables -L RKN_GEOIP_HOOK -v -n
sudo iptables -L GEOIP_DROP -v -n

sudo ipset list TSPUIPS | head -20
sudo ipset list GOVIPS | head -20
sudo ipset list GEOIP_ALLOW_IPS | head -20
sudo ipset list GEOIP_DENY_IPS | head -20
sudo ipset list GEOIP_COUNTRIES_ALLOW | head -20
```
