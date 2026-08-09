# Конфигурация

## 1. settings.conf

Файл:

```text
/etc/rkn-watcher/settings.conf
```

Поддерживаемые ключи:

### `FILTER_PORTS`
Определяет, на какие TCP-порты применяется GeoIP-цепочка.

Возможные значения:

- `all`
- `443`
- `80,443,8443`

Примеры:

```ini
FILTER_PORTS="all"
FILTER_PORTS="443"
FILTER_PORTS="80,443,8443"
```

### `LOG_RST`
Включает/выключает логирование RST-блокировок для `TSPUBLOCK` и `GOVIPS`.

```ini
LOG_RST="y"
LOG_RST="n"
```

### `AUTO_UPDATE`
Управляет включением `systemd timer`.

```ini
AUTO_UPDATE="y"
AUTO_UPDATE="n"
```

### `ENABLE_TSPUBLOCK`
```ini
ENABLE_TSPUBLOCK="y"
ENABLE_TSPUBLOCK="n"
```

### `ENABLE_GOVIPS`
```ini
ENABLE_GOVIPS="y"
ENABLE_GOVIPS="n"
```

## 2. whitelist.json

Файл:

```text
/etc/rkn-watcher/whitelist.json
```

Пример:

```json
{
    "enabled": true,
    "countries": ["RU", "FI"],
    "ips": ["1.2.3.4", "10.0.0.0/24"],
    "ports": [22, 443]
}
```

Поля:

- `enabled` — включён ли GeoIP-фильтр;
- `countries` — список разрешённых стран;
- `ips` — список разрешённых IPv4-адресов/CIDR;
- `ports` — список разрешённых TCP-портов.

`enabled` должен быть JSON-boolean: `true` или `false`. Для совместимости helper читает распространённые legacy-значения, например `"true"` и `"false"`, но всегда записывает JSON-boolean.

Поддерживаются только IPv4-адреса и IPv4-сети; IPv6-адреса и сети отклоняются.

## 3. blacklist.json

Файл:

```text
/etc/rkn-watcher/blacklist.json
```

Пример:

```json
{
    "ips": ["203.0.113.5", "198.51.100.0/24"],
    "ports": [25, 3389]
}
```

Поля:

- `ips` — список запрещённых IPv4-адресов/CIDR;
- `ports` — список запрещённых TCP-портов.

## 4. Порядок применения GeoIP-правил

При включённом GeoIP:

1. deny IP/CIDR → `DROP`
2. allow IP/CIDR → `RETURN`
3. deny ports → `DROP`
4. allow ports → `RETURN`
5. allow countries → `RETURN`
6. всё остальное → `DROP`

Если список стран пуст, country-based drop не применяется, и цепочка завершится `RETURN`.

## 5. Ручное редактирование

Можно редактировать JSON вручную, но после этого нужно выполнить:

```bash
sudo rkn-watcher apply
```

Однако предпочтительно использовать встроенное меню или helper-команды.

## 6. Helper-команды

Скрипт `config_tool.py` удерживает один advisory lock на весь цикл чтения, изменения и записи, поэтому параллельные вызовы не теряют изменения конфигурации. Используйте его вместо одновременных ручных правок:

```bash
sudo /opt/rkn-watcher/config_tool.py add-country FI
sudo /opt/rkn-watcher/config_tool.py remove-country FI
sudo /opt/rkn-watcher/config_tool.py add-ip 1.2.3.4
sudo /opt/rkn-watcher/config_tool.py remove-ip 1.2.3.4
sudo /opt/rkn-watcher/config_tool.py add-port 443
sudo /opt/rkn-watcher/config_tool.py remove-port 443
sudo /opt/rkn-watcher/config_tool.py add-deny-ip 203.0.113.5
sudo /opt/rkn-watcher/config_tool.py add-deny-port 25
sudo /opt/rkn-watcher/config_tool.py show all
```
