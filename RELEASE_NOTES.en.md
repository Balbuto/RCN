# Release Notes — RKN Watcher v3.1.0

## Summary

Release `v3.1.0` is a maintenance and reliability update for the v3 firewall-management workflow. It prevents lost JSON configuration changes, handles legacy boolean values safely, and validates the IPv4-only boundary of the current `ipset` implementation.

## Fixed in v3.1.0

- The JSON configuration lock now covers the entire read-modify-write operation. Concurrent `config_tool.py` calls no longer overwrite one another's additions or removals.
- `enabled: "false"` and other supported legacy boolean representations are normalized correctly; a non-empty string no longer accidentally enables GeoIP.
- IPv6 addresses and networks are rejected consistently by the menu, configuration tool, and GeoIP apply path. The project currently creates IPv4 `ipset` sets only.
- `SHA256SUMS` was regenerated to cover the actual tracked release files and no longer references files absent from the repository.

## Documentation and tests

- Updated the English and Russian release, configuration, security, migration, troubleshooting, test, and publishing documentation for v3.1.
- Added mock coverage for concurrent configuration updates, legacy boolean normalization, and IPv6 rejection.
- GitHub Actions now verifies `SHA256SUMS` after syntax and mock tests.

## Upgrade from v3.0.x

1. Update the working tree.
2. Confirm that `whitelist.json` and `blacklist.json` contain only IPv4 entries.
3. Run the installer upgrade:

```bash
git pull
sudo ./installer.sh install
```

Existing JSON configuration remains supported. For manual edits, use the JSON boolean values `true` and `false` for `enabled`.

## Minimal publishing flow

```bash
bash -n installer.sh rkn-watcher.sh
python3 -m py_compile config_tool.py geoip_apply.py
chmod +x tests/run_tests.sh
./tests/run_tests.sh
sha256sum -c SHA256SUMS
git add .
git commit -m "Release v3.1.0"
git tag -a v3.1.0 -m "RKN Watcher v3.1.0"
git push origin main v3.1.0
```

## Minimal end-user install flow

```bash
git clone https://github.com/Balbuto/RCN.git
cd RCN
chmod +x installer.sh rkn-watcher.sh
sudo ./installer.sh
```
