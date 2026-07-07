# Release Notes — RKN Watcher v3.0.0

## Summary

Release `v3.0.0` is a rewritten and stabilized version of the project with safe `ipset` updates, a dedicated interactive installer, and automated mock tests.

## Included in this release

- `installer.sh` — recommended entry point for installation and removal
- `rkn-watcher.sh` — main control script
- `config_tool.py` — safe configuration editor
- `geoip_apply.py` — applies GeoIP / allow / deny rules
- `tests/run_tests.sh` — mock tests for `iptables` / `ipset` logic
- full documentation in Russian and English under `docs/`
- a GitHub Actions workflow to run tests on push and pull requests

## Key improvements

- fixed the false-success bug on failed list download;
- `TSPUBLOCK` and `GOVIPS` updates are now atomic;
- duplicate `iptables` rules are prevented;
- uses a `systemd timer` instead of `cron + daemon polling`;
- full uninstall removes only managed changes;
- configuration updates are safe: lock + atomic write;
- added a separate interactive installer with root and dependency checks.

## Minimal publishing flow

```bash
git init
git add .
git commit -m "Release v3.0.0"
git branch -M main
git remote add origin <YOUR_REPO_URL>
git push -u origin main
```

## Minimal end-user install flow

```bash
git clone <YOUR_REPO_URL>
cd RCN
chmod +x installer.sh rkn-watcher.sh
sudo ./installer.sh
```
