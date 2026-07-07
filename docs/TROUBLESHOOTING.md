# Решение проблем

## 1. Установщик сообщает, что запущен не от root

Решение:

```bash
sudo ./installer.sh
```

Или:

```bash
sudo ./rkn-watcher.sh install
```

## 2. Скрипт пишет, что helper-файлы не найдены

Причина: `rkn-watcher.sh` запущен отдельно, без `config_tool.py` и `geoip_apply.py`.

Решение:
- используйте `git clone`;
- либо положите `installer.sh`, `rkn-watcher.sh`, `config_tool.py`, `geoip_apply.py` в одну директорию.

## 2. Не загружаются списки TSPUBLOCK / GOVIPS

Проверьте сеть:

```bash
curl -I https://github.com/
curl -I https://raw.githubusercontent.com/
```

Проверьте лог:

```bash
sudo tail -n 100 /var/log/rkn-watcher/update.log
```

Важно: в v3 при ошибке загрузки старый рабочий `ipset` сохраняется, а не очищается.

## 3. Country GeoIP не применяет список стран

Проверьте:

```bash
sudo cat /etc/rkn-watcher/whitelist.json
sudo ipset list GEOIP_COUNTRIES_ALLOW | head -20
```

Если `GEOIP_COUNTRIES_ALLOW` пуст:
- проверьте доступ к `ipdeny.com`;
- проверьте код страны, например `FI`, `DE`, `JP`.

## 4. После изменения конфига правила не обновились

Выполните вручную:

```bash
sudo rkn-watcher apply
```

## 5. Timer не запускается

Проверьте:

```bash
systemctl status rkn-watcher-update.timer
systemctl status rkn-watcher-update.service
systemctl list-timers | grep rkn-watcher
```

Если таймер выключен, включите:

```bash
sudo systemctl enable --now rkn-watcher-update.timer
```

## 6. Цепочки не видны в iptables

Проверьте, что правила применены:

```bash
sudo rkn-watcher apply
sudo iptables -L INPUT -v -n
```

## 7. Включён GeoIP, но доступ пропал слишком широко

Вероятная причина:
- включён `enabled=true`,
- заполнены `countries`,
- ваша страна/адрес не попали в allow-набор.

Решение:
- временно добавить ваш IP в allow;
- либо отключить GeoIP;
- затем скорректировать список стран.

## 8. Как быстро отключить только GeoIP, не трогая TSPU/GOV

Через меню или командой:

```bash
sudo /opt/rkn-watcher/config_tool.py set-enabled false
sudo rkn-watcher apply
```

## 9. Как полностью отключить обновления

Через меню, либо так:

```bash
sudo systemctl disable --now rkn-watcher-update.timer
```

## 10. Как удалить программу

```bash
sudo rkn-watcher uninstall
```
