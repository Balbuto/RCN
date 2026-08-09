# Решение проблем

## 1. Установщик сообщает, что запущен не от root

```bash
sudo ./installer.sh
```

Или для установки без меню:

```bash
sudo ./rkn-watcher.sh install
```

## 2. Скрипт сообщает, что helper-файлы не найдены

Причина: `rkn-watcher.sh` запущен отдельно, без `config_tool.py` и `geoip_apply.py`.

Решение:
- используйте `git clone`;
- либо положите `installer.sh`, `rkn-watcher.sh`, `config_tool.py` и `geoip_apply.py` в одну директорию.

## 3. Не загружаются списки TSPUBLOCK / GOVIPS

Проверьте сеть:

```bash
curl -I https://github.com/
curl -I https://raw.githubusercontent.com/
```

Проверьте лог:

```bash
sudo tail -n 100 /var/log/rkn-watcher/update.log
```

Важно: в v3.1 при ошибке загрузки старый рабочий `ipset` сохраняется, а не очищается.

## 4. Country GeoIP не применяет список стран

Проверьте:

```bash
sudo cat /etc/rkn-watcher/whitelist.json
sudo ipset list GEOIP_COUNTRIES_ALLOW | head -20
```

Если `GEOIP_COUNTRIES_ALLOW` пуст:
- проверьте доступ к `ipdeny.com`;
- проверьте код страны, например `FI`, `DE`, `JP`.

## 5. После изменения конфига правила не обновились

```bash
sudo rkn-watcher apply
```

## 6. Timer не запускается

```bash
systemctl status rkn-watcher-update.timer
systemctl status rkn-watcher-update.service
systemctl list-timers | grep rkn-watcher
```

Если таймер выключен:

```bash
sudo systemctl enable --now rkn-watcher-update.timer
```

## 7. Цепочки не видны в iptables

Проверьте, что правила применены:

```bash
sudo rkn-watcher apply
sudo iptables -L INPUT -v -n
```

## 8. Включён GeoIP, но доступ пропал слишком широко

Вероятная причина:
- включён `enabled=true`;
- заполнены `countries`;
- ваша страна или адрес не попали в allow-набор.

Решение:
- временно добавить ваш IPv4-адрес в allow;
- либо отключить GeoIP;
- затем скорректировать список стран.

## 9. IPv6-адрес или сеть отклонены

Для v3.1 это ожидаемое поведение: текущие firewall-наборы работают только с IPv4. Удалите IPv6-запись из `whitelist.json` или `blacklist.json` либо замените её нужным IPv4-адресом/CIDR, затем примените правила:

```bash
sudo rkn-watcher apply
```

## 10. Как быстро отключить только GeoIP, не трогая TSPU/GOV

Через меню или командой:

```bash
sudo /opt/rkn-watcher/config_tool.py set-enabled false
sudo rkn-watcher apply
```

## 11. Как полностью отключить обновления

Через меню, либо так:

```bash
sudo systemctl disable --now rkn-watcher-update.timer
```

## 12. Как удалить программу

```bash
sudo rkn-watcher uninstall
```
