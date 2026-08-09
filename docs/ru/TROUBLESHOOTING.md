# Решение проблем

## Установщик сообщает, что он запущен не от root

Запускай так:

```bash
sudo ./installer.sh
```

## Не найдены helper-файлы

Причина: `rkn-watcher.sh` запущен отдельно, без `config_tool.py` и `geoip_apply.py`.

Решение:
- использовать `git clone`;
- либо положить `installer.sh`, `rkn-watcher.sh`, `config_tool.py`, `geoip_apply.py` в одну директорию.

## Не загружаются списки TSPUBLOCK / GOVIPS

Проверь сеть:

```bash
curl -I https://github.com/
curl -I https://raw.githubusercontent.com/
```

Проверь лог:

```bash
sudo tail -n 100 /var/log/rkn-watcher/update.log
```

Важно: в v3.1 при ошибке загрузки старый рабочий `ipset` сохраняется.

## Country GeoIP не применяет список стран

Проверь:

```bash
sudo cat /etc/rkn-watcher/whitelist.json
sudo ipset list GEOIP_COUNTRIES_ALLOW | head -20
```

Если набор пуст:
- проверь доступ к `ipdeny.com`;
- проверь код страны, например `FI`, `DE`, `JP`.

## После изменения конфига правила не обновились

```bash
sudo rkn-watcher apply
```

## Timer не запускается

```bash
systemctl status rkn-watcher-update.timer
systemctl status rkn-watcher-update.service
systemctl list-timers | grep rkn-watcher
```

Если таймер выключен:

```bash
sudo systemctl enable --now rkn-watcher-update.timer
```

## Включён GeoIP и доступ пропал слишком широко

Вероятная причина:
- `enabled=true`;
- заполнены `countries`;
- твой IP или страна не попали в allow-набор.

Решение:
- временно добавить свой IP в allow;
- либо отключить GeoIP;
- затем скорректировать список стран.

## IPv6-адрес или сеть отклонены

Для v3.1 это ожидаемое поведение: текущие firewall-наборы работают только с IPv4. Удалите IPv6-запись из `whitelist.json` или `blacklist.json` либо замените её нужным IPv4-адресом/CIDR, затем повторно примените правила:

```bash
sudo rkn-watcher apply
```

## Как быстро отключить только GeoIP

```bash
sudo /opt/rkn-watcher/config_tool.py set-enabled false
sudo rkn-watcher apply
```
