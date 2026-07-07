# Changelog

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
