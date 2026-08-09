# Troubleshooting

## Installer says it is not running as root

Run it like this:

```bash
sudo ./installer.sh
```

## Helper files are missing

Reason: `rkn-watcher.sh` was started without `config_tool.py` and `geoip_apply.py` nearby.

Solution:
- use `git clone`;
- or place `installer.sh`, `rkn-watcher.sh`, `config_tool.py`, and `geoip_apply.py` in the same directory.

## TSPUBLOCK / GOVIPS lists do not download

Check connectivity:

```bash
curl -I https://github.com/
curl -I https://raw.githubusercontent.com/
```

Check the log:

```bash
sudo tail -n 100 /var/log/rkn-watcher/update.log
```

Important: in v3.1, the previous working `ipset` set is preserved if download fails.

## Country GeoIP does not apply country rules

Check:

```bash
sudo cat /etc/rkn-watcher/whitelist.json
sudo ipset list GEOIP_COUNTRIES_ALLOW | head -20
```

If the set is empty:
- verify access to `ipdeny.com`;
- verify the country code, for example `FI`, `DE`, `JP`.

## Rules were not refreshed after config changes

```bash
sudo rkn-watcher apply
```

## Timer does not start

```bash
systemctl status rkn-watcher-update.timer
systemctl status rkn-watcher-update.service
systemctl list-timers | grep rkn-watcher
```

If disabled:

```bash
sudo systemctl enable --now rkn-watcher-update.timer
```

## GeoIP is enabled and access is blocked too broadly

Likely reason:
- `enabled=true`;
- `countries` are configured;
- your IP or country is not in the allow set.

Solution:
- temporarily add your IP to allow;
- or disable GeoIP;
- then adjust the country list.

## An IPv6 address or network is rejected

This is expected in v3.1: the current firewall sets are IPv4-only. Remove the IPv6 entry from `whitelist.json` or `blacklist.json`, or replace it with the required IPv4 address/CIDR, then apply the rules again:

```bash
sudo rkn-watcher apply
```

## Quickly disable only GeoIP

```bash
sudo /opt/rkn-watcher/config_tool.py set-enabled false
sudo rkn-watcher apply
```
