# RKN Watcher v3.1.0

RKN Watcher — набор скриптов для Linux-серверов Debian/Ubuntu, который:

- загружает и обновляет списки `TSPUBLOCK` и `GOVIPS`;
- применяет блокировку через `iptables` + `ipset`;
- умеет фильтровать доступ по странам, allow/deny IP и портам;
- выполняет атомарное обновление списков без потери рабочего набора при сетевой ошибке;
- использует `systemd timer` вместо связки `cron + daemon polling`.

## Главное в версии v3.1

- сохранены атомарное обновление `ipset` и защита от дублей правил из v3;
- весь цикл чтения, изменения и записи JSON-конфигурации защищён file lock, поэтому параллельные изменения не теряются;
- legacy-значения boolean, например `"false"`, обрабатываются безопасно и не включают GeoIP по ошибке;
- IPv6-адреса и сети последовательно отклоняются: текущие `ipset`-наборы работают только с IPv4;
- GitHub Actions проверяет `SHA256SUMS`, а документация описывает проверку контрольных сумм перед публикацией;
- mock-тесты покрывают параллельное редактирование конфигурации, нормализацию boolean и отклонение IPv6.

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
