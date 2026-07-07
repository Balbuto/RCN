# Release Notes — RKN Watcher v3.0.0

## Основное

Релиз `v3.0.0` — это переписанная и стабилизированная версия проекта с безопасным обновлением `ipset`, отдельным интерактивным установщиком и набором автотестов.

## Что входит в релиз

- `installer.sh` — рекомендуемая точка входа для установки и удаления
- `rkn-watcher.sh` — основной управляющий скрипт
- `config_tool.py` — безопасное редактирование конфигурации
- `geoip_apply.py` — применение GeoIP / allow / deny правил
- `tests/run_tests.sh` — mock-тесты логики `iptables` / `ipset`
- полная документация на русском и английском в `docs/`
- GitHub Actions workflow для запуска тестов при публикации

## Ключевые улучшения

- исправлен баг ложного успеха при неудачном обновлении списков;
- обновление `TSPUBLOCK` и `GOVIPS` выполняется атомарно;
- предотвращено накопление дублей в `iptables`;
- используется `systemd timer` вместо `cron + daemon polling`;
- full uninstall удаляет только управляемые изменения;
- конфигурация обновляется безопасно: lock + atomic write;
- добавлен отдельный интерактивный установщик с контролем root и зависимостей.

## Минимальный сценарий публикации

```bash
git init
git add .
git commit -m "Release v3.0.0"
git branch -M main
git remote add origin <YOUR_REPO_URL>
git push -u origin main
```

## Минимальный сценарий установки пользователем

```bash
git clone <YOUR_REPO_URL>
cd RCN
chmod +x installer.sh rkn-watcher.sh
sudo ./installer.sh
```
