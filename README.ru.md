# RKN Watcher v3.0.0

RKN Watcher — набор скриптов для Linux-серверов Debian/Ubuntu, который:

- загружает и обновляет списки `TSPUBLOCK` и `GOVIPS`;
- применяет блокировку через `iptables` + `ipset`;
- умеет фильтровать доступ по странам, allow/deny IP и портам;
- выполняет атомарное обновление списков без потери рабочего набора при сетевой ошибке;
- использует `systemd timer` вместо связки `cron + daemon polling`.

## Главное в версии v3

- исправлено обнуление `ipset` при обычном `apply`;
- update теперь возвращает ошибку корректно, если список не удалось скачать;
- обновление списков стало атомарным: временный set + `ipset swap`;
- исключено накопление дублирующихся `iptables`-правил;
- убран конфликт `cron` и фонового демона;
- JSON-конфигурация редактируется безопасно: lock + atomic write;
- GeoIP по странам теперь реально применяется по country CIDR;
- удаление программы больше не трогает чужие системные firewall-файлы целиком.

## Состав репозитория

```text
RCN/
├── installer.sh
├── rkn-watcher.sh
├── config_tool.py
├── geoip_apply.py
├── README.ru.md / README.en.md
├── CHANGELOG.ru.md / CHANGELOG.en.md
├── RELEASE_NOTES.ru.md / RELEASE_NOTES.en.md
├── PUBLISHING.ru.md / PUBLISHING.en.md
├── docs/
│   ├── ru/
│   └── en/
└── tests/
```

## Быстрый старт

```bash
git clone https://github.com/Balbuto/RCN.git
cd RCN
chmod +x installer.sh rkn-watcher.sh
sudo ./installer.sh
```

Установщик:
- проверяет запуск от `root`;
- проверяет зависимости;
- устанавливает отсутствующие пакеты;
- запускает основной интерактивный процесс установки;
- умеет выполнять полное удаление внесённых изменений.

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
sudo ./rkn-watcher.sh install
sudo ./rkn-watcher.sh update
sudo ./rkn-watcher.sh apply
sudo ./rkn-watcher.sh status
sudo ./rkn-watcher.sh uninstall
```

После установки также создаётся команда:

```bash
sudo rkn-watcher
```

## Поддерживаемая среда

- Debian 11 / 12
- Ubuntu 20.04 / 22.04 / 24.04
- IPv4 для country-based GeoIP
- Требуются права `root`

## Источники данных

- TSPU / Skipa CIDR: `https://github.com/tread-lightly/CyberOK_Skipa_ips`
- GOVIPS / blacklist-v4.ipset: `https://github.com/C24Be/AS_Network_List`
- Country CIDR: `https://www.ipdeny.com/ipblocks/`

## Документация

- [Установка](docs/ru/INSTALL.md)
- [Интерактивный установщик](docs/ru/INSTALLER.md)
- [Использование](docs/ru/USAGE.md)
- [Конфигурация](docs/ru/CONFIGURATION.md)
- [Миграция](docs/ru/MIGRATION.md)
- [Решение проблем](docs/ru/TROUBLESHOOTING.md)
- [Безопасность](docs/ru/SECURITY.md)

## Лицензия

MIT. См. файл [LICENSE](LICENSE).
