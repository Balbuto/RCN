# Тесты

В этой папке лежит небольшой набор безопасных mock-тестов для проверки логики `iptables` / `ipset` без изменения реального firewall сервера.

## Что проверяется

### Для `rkn-watcher.sh`
- корректное добавление `TSPUBLOCK` и `GOVIPS`;
- отсутствие дублирования hook-правил в `INPUT`;
- успешное наполнение `ipset` при update;
- корректная ошибка при неудачной загрузке списков;
- сохранение старого рабочего `ipset` при сбое update;
- очистка управляемых цепочек и `ipset` через `remove_managed_firewall()`.

### Для `geoip_apply.py`
- создание `GEOIP_ALLOW_IPS`, `GEOIP_DENY_IPS`, `GEOIP_COUNTRIES_ALLOW`;
- корректное построение цепочек `RKN_GEOIP_HOOK` и `GEOIP_DROP`;
- отсутствие дублирования hook в `INPUT` при повторном apply;
- очистка hook и цепочек при `enabled=false`.

## Запуск

Из корня репозитория:

```bash
chmod +x tests/run_tests.sh
./tests/run_tests.sh
```

## Требования

- `bash`
- `python3`
- запуск от обычного пользователя допустим
- root не нужен

## Примечание

Это не integration-тесты реального kernel firewall, а тесты логики скриптов через mock-реализации `iptables`, `ipset`, `curl` и связанных команд.
