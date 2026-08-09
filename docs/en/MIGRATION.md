# Migration to v3.1

## What changed

Older project versions had several issues:
- clearing `ipset` before a new list was successfully downloaded;
- duplicated `iptables` rules on repeated apply;
- conflict between `cron` and a background daemon;
- partially unsafe handling of user input;
- removing global firewall files during uninstall;
- country-based GeoIP was declared but not enforced as a real country filter.

Version v3 introduced the current atomic update, systemd, and CIDR-filtering design. Version v3.1 additionally protects the complete JSON configuration read-modify-write operation, normalizes legacy boolean values safely, and rejects IPv6 entries before they reach IPv4-only `ipset` sets.

## Before upgrading

1. Back up `/etc/rkn-watcher/` if it contains configuration you need.
2. Remove IPv6 addresses or networks from `whitelist.json` and `blacklist.json`; v3.1 accepts IPv4 entries only.
3. If you edit JSON manually, use the JSON boolean values `true` and `false` for `enabled`.

## Recommended upgrade path

### Option 1. Upgrade an existing v3 installation

```bash
cd RCN
git pull
sudo ./installer.sh install
```

Choose to preserve the current configuration when prompted, then run:

```bash
sudo rkn-watcher apply
sudo rkn-watcher status
```

### Option 2. Clean install from an older release

1. remove the old version;
2. install v3.1 with `sudo ./installer.sh`;
3. migrate only the required IPv4 allow/deny entries and country codes;
4. review the country list before enabling GeoIP.

## What to verify after migration

```bash
sudo rkn-watcher status
sudo iptables -L INPUT -v -n
sudo ipset list TSPUIPS | head
sudo ipset list GOVIPS | head
sudo ipset list GEOIP_COUNTRIES_ALLOW | head
```

To verify the downloaded release files before installation:

```bash
sha256sum -c SHA256SUMS
```
