# Security and limitations

## Security improvements in v3

- user input is no longer interpolated directly into inline Python code;
- JSON configuration is written atomically via a temporary file and `os.replace()`;
- JSON updates use file locking;
- concurrent `update/apply` operations are serialized with `flock`;
- `ipset` updates are atomic through a temporary set and `swap`.

## Important operational notes

### The scripts run as root
This is required to manage `iptables`, `ipset`, and `systemd`.

### Country-based GeoIP depends on an external CIDR source
The project uses `ipdeny.com`.
If the source is unavailable:
- cached data is used if present;
- if there is no cache, that country set cannot be refreshed.

### IPv6 is not supported
The current implementation works with IPv4 only (`family inet`).

### Country GeoIP here is CIDR-based filtering, not a MaxMind GeoIP database
The mapping is based on published country network block lists.

### Not recommended on hosts where `iptables` is fully controlled by another system
Examples:
- an orchestration layer;
- a panel-provided firewall manager;
- a configuration management system that rewrites `iptables` entirely.
