# Usage

## Main commands

### Via installer
```bash
sudo ./installer.sh
sudo ./installer.sh install
sudo ./installer.sh uninstall
sudo ./installer.sh deps
sudo ./installer.sh status
```

### Via main script
```bash
sudo rkn-watcher install
sudo rkn-watcher update
sudo rkn-watcher apply
sudo rkn-watcher status
sudo rkn-watcher uninstall
sudo rkn-watcher --help
```

## Interactive menu

Run:

```bash
sudo rkn-watcher
```

Menu sections:
- **Blocklists** — enable/disable `TSPUBLOCK` and `GOVIPS`, update lists, show `iptables` / `ipset` state;
- **GeoIP** — enable/disable, countries, allow/deny IPs and ports;
- **Settings** — `FILTER_PORTS`, `LOG_RST`, `AUTO_UPDATE`, re-apply rules;
- **Status**;
- **Logs**;
- **Reinstall / update**;
- **Uninstall**.

### GeoIP input in v3.1

Allow/deny IP entries accept IPv4 addresses and CIDRs only. Use the menu or `config_tool.py` for serialized configuration changes; after a manual configuration edit, run `sudo rkn-watcher apply`.

## Updating blocklists

Manual run:

```bash
sudo rkn-watcher update
```

Scheduled run:
- handled by `rkn-watcher-update.timer`;
- default schedule is daily at `03:00`.

## Re-applying rules

```bash
sudo rkn-watcher apply
```

## Viewing logs

```bash
sudo tail -n 100 /var/log/rkn-watcher/update.log
sudo tail -n 100 /var/log/rkn-watcher/actions.log
sudo tail -n 100 /var/log/rkn-watcher/geoip.log
```

## Checking timer status

```bash
systemctl status rkn-watcher-update.timer
systemctl list-timers | grep rkn-watcher
```

## Checking rules and sets

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
