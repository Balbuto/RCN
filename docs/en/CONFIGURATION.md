# Configuration

## settings.conf

File:

```text
/etc/rkn-watcher/settings.conf
```

Keys:

### `FILTER_PORTS`
Defines which TCP ports the GeoIP hook applies to.

Examples:

```ini
FILTER_PORTS="all"
FILTER_PORTS="443"
FILTER_PORTS="80,443,8443"
```

### `LOG_RST`
Enables/disables RST logging for `TSPUBLOCK` and `GOVIPS`.

### `AUTO_UPDATE`
Enables/disables the `systemd timer`.

### `ENABLE_TSPUBLOCK`
Enables/disables `TSPUBLOCK`.

### `ENABLE_GOVIPS`
Enables/disables `GOVIPS`.

## whitelist.json

```text
/etc/rkn-watcher/whitelist.json
```

Example:

```json
{
  "enabled": true,
  "countries": ["RU", "FI"],
  "ips": ["1.2.3.4", "10.0.0.0/24"],
  "ports": [22, 443]
}
```

Fields:
- `enabled` — whether GeoIP filtering is enabled;
- `countries` — allowed countries;
- `ips` — allowed IPs/CIDRs;
- `ports` — allowed TCP ports.

## blacklist.json

```text
/etc/rkn-watcher/blacklist.json
```

Example:

```json
{
  "ips": ["203.0.113.5", "198.51.100.0/24"],
  "ports": [25, 3389]
}
```

## GeoIP evaluation order

1. deny IP/CIDR → `DROP`
2. allow IP/CIDR → `RETURN`
3. deny ports → `DROP`
4. allow ports → `RETURN`
5. allow countries → `RETURN`
6. everything else → `DROP`

If the country list is empty, country-based drop is not applied and the chain ends with `RETURN`.

## Safe editing with helper tool

```bash
sudo /opt/rkn-watcher/config_tool.py add-country FI
sudo /opt/rkn-watcher/config_tool.py remove-country FI
sudo /opt/rkn-watcher/config_tool.py add-ip 1.2.3.4
sudo /opt/rkn-watcher/config_tool.py add-port 443
sudo /opt/rkn-watcher/config_tool.py add-deny-ip 203.0.113.5
sudo /opt/rkn-watcher/config_tool.py add-deny-port 25
sudo /opt/rkn-watcher/config_tool.py show all
```

After manual config edits, run:

```bash
sudo rkn-watcher apply
```
