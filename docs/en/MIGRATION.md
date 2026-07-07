# Migration from older versions

## What changed

Older versions of the project had several issues:
- clearing `ipset` before a new list was successfully downloaded;
- duplicated `iptables` rules on repeated apply;
- conflict between `cron` and a background daemon;
- partially unsafe handling of user input;
- removing global firewall files during uninstall;
- country-based GeoIP was declared but not enforced as a real country filter.

Version v3 resolves these issues.

## Recommended upgrade path

### Option 1. Clean install
1. remove the old version;
2. install v3 with `sudo ./installer.sh`;
3. review allow/deny rules and the country list.

### Option 2. Careful migration
1. save old whitelist/blacklist values;
2. disable old cron/daemon mechanisms;
3. install v3;
4. migrate only the user data you still need into the new config files;
5. run `sudo rkn-watcher apply`.

## What to verify after migration

```bash
sudo rkn-watcher status
sudo iptables -L INPUT -v -n
sudo ipset list TSPUIPS | head
sudo ipset list GOVIPS | head
sudo ipset list GEOIP_COUNTRIES_ALLOW | head
```
