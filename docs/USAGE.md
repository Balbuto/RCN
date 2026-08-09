# Использование

## 1. Основные команды CLI

### Через рекомендуемый установщик

```bash
sudo ./installer.sh
sudo ./installer.sh install
sudo ./installer.sh uninstall
sudo ./installer.sh deps
sudo ./installer.sh status
```

### Через основной исполняемый скрипт

```bash
sudo rkn-watcher install
sudo rkn-watcher update
sudo rkn-watcher apply
sudo rkn-watcher status
sudo rkn-watcher uninstall
sudo rkn-watcher --help
```

### Что делает каждая команда

- `install` — установка или обновление файлов программы;
- `update` — загрузка и атомарное обновление `TSPUBLOCK` и `GOVIPS`;
- `apply` — повторное применение правил из текущей конфигурации;
- `status` — сводка по состоянию;
- `uninstall` — полное удаление программы;
- без аргументов — интерактивное меню.

## 2. Интерактивное меню

Запуск:

```bash
sudo rkn-watcher
```

Основные разделы:

- **Блок-листы**
  - вкл/выкл `TSPUBLOCK`
  - вкл/выкл `GOVIPS`
  - обновить оба списка
  - показать текущие `iptables`/`ipset`

- **GeoIP**
  - вкл/выкл GeoIP
  - добавить/удалить страну
  - добавить/удалить allow IP/CIDR
  - добавить/удалить allow port
  - добавить/удалить deny IP/CIDR
  - добавить/удалить deny port
  - показать текущую конфигурацию

- **Настройки**
  - изменить `FILTER_PORTS`
  - вкл/выкл `LOG_RST`
  - вкл/выкл `AUTO_UPDATE`
  - пере-применить правила

- **Статус**
- **Логи**
- **Переустановить / обновить**
- **Удалить**

### Ввод GeoIP в v3.1

Allow/deny IP принимают только IPv4-адреса и CIDR. Используйте меню или `config_tool.py` для сериализованных изменений конфигурации; после ручной правки выполните `sudo rkn-watcher apply`.

## 3. Обновление списков

Ручной запуск:

```bash
sudo rkn-watcher update
```

Плановый запуск:
- выполняется через `rkn-watcher-update.timer`;
- по умолчанию — ежедневно в `03:00`;
- можно отключить через меню.

## 4. Повторное применение правил

После ручного редактирования конфигов или после диагностики:

```bash
sudo rkn-watcher apply
```

## 5. Просмотр логов

Файлы логов:

```bash
sudo tail -n 100 /var/log/rkn-watcher/update.log
sudo tail -n 100 /var/log/rkn-watcher/actions.log
sudo tail -n 100 /var/log/rkn-watcher/geoip.log
```

## 6. Проверка таймера

```bash
systemctl status rkn-watcher-update.timer
systemctl list-timers | grep rkn-watcher
```

## 7. Проверка firewall-правил

```bash
sudo iptables -L INPUT -v -n
sudo iptables -L TSPUBLOCK -v -n
sudo iptables -L GOVBLOCK -v -n
sudo iptables -L RKN_GEOIP_HOOK -v -n
sudo iptables -L GEOIP_DROP -v -n
```

## 8. Проверка ipset

```bash
sudo ipset list TSPUIPS | head -20
sudo ipset list GOVIPS | head -20
sudo ipset list GEOIP_ALLOW_IPS | head -20
sudo ipset list GEOIP_DENY_IPS | head -20
sudo ipset list GEOIP_COUNTRIES_ALLOW | head -20
```
