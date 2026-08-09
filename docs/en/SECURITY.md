# Security and limitations

## Security improvements in v3.1

- user input is not interpolated directly into inline Python code;
- JSON configuration is written atomically via a temporary file and `os.replace()`;
- one advisory file lock now covers the full configuration read-modify-write operation, preventing concurrent editor calls from losing changes;
- legacy boolean values are parsed explicitly, so `"false"` is not treated as a truthy value that enables GeoIP;
- concurrent `update` and `apply` operations are serialized with `flock`;
- `ipset` updates are atomic through a temporary set and `swap`;
- the checksum manifest is verified in GitHub Actions and in the documented release checklist.

## Important operational notes

### The scripts run as root

This is required to manage `iptables`, `ipset`, and `systemd`. Review country, allow, and deny rules carefully before enabling GeoIP on a remotely administered host.

### Country-based GeoIP depends on an external CIDR source

The project uses `ipdeny.com`.
If the source is unavailable:
- cached data is used if present;
- if there is no cache, that country set cannot be refreshed.

### IPv6 is not supported

The current implementation creates IPv4 `ipset` sets (`family inet`). IPv6 addresses and networks are rejected by the menu, `config_tool.py`, and the GeoIP apply path instead of being passed to an incompatible set.

### Country GeoIP here is CIDR-based filtering, not a MaxMind GeoIP database

The mapping is based on published country network block lists.

### Not recommended on hosts where `iptables` is fully controlled by another system

Examples:
- an orchestration layer;
- a panel-provided firewall manager;
- a configuration management system that rewrites `iptables` entirely.
