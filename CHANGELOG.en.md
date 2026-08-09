# Changelog

## v3.1.0 — 2026-08-09

### Fixed
- configuration edits no longer lose updates when several `config_tool.py` commands run at the same time: one lock now covers the full read-modify-write operation;
- legacy boolean configuration values are normalized safely, so a string such as `"false"` does not enable GeoIP;
- IPv6 addresses and networks are rejected before they can reach IPv4-only `ipset` sets and cause a failed apply;
- regenerated `SHA256SUMS`: it now covers every tracked release file and no longer references absent files.

### Documentation and validation
- updated release, installation, configuration, security, migration, troubleshooting, test, and publishing documentation for v3.1;
- added checksum validation to GitHub Actions and the publishing checklist;
- added mock tests for concurrent configuration writes, boolean normalization, and IPv6 rejection.

## v3.0.0

### Fixes
- fixed the bug where `setup_*` could clear already loaded `ipset` sets;
- switched `TSPUBLOCK` and `GOVIPS` updates to an atomic `temp set + swap` model;
- parallel list download failures no longer appear as successful updates;
- fixed the bug where update could return success even when list download failed;
- removed duplicate `INPUT -> GEOIP` rule accumulation;
- removed unsafe inline Python interpolation of user input;
- uninstall no longer removes global `/etc/ipset.conf` and `/etc/iptables/rules.v4` files.

### Architectural changes
- replaced `cron + daemon` with a single `systemd timer`;
- moved helper logic into `config_tool.py` and `geoip_apply.py`;
- added a dedicated interactive installer `installer.sh`;
- removed the `venv` dependency;
- rule restore after reboot is handled by a `systemd oneshot` service.

### Functional changes
- country-based GeoIP is now actually enforced through country CIDR sets;
- added allow/deny IP and allow/deny port rules;
- configuration files are updated with file locking and atomic writes;
- input values are validated with Python `ipaddress` and strict port checks.

### Limitations
- country-based GeoIP currently supports IPv4 only;
- country filtering relies on an external CIDR source (`ipdeny`).
