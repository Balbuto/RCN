# RKN Watcher v3.1.0

RKN Watcher is a set of scripts for Debian/Ubuntu Linux servers that:

- downloads and updates `TSPUBLOCK` and `GOVIPS` lists;
- applies filtering with `iptables` + `ipset`;
- supports country-based filtering plus allow/deny IP and port rules;
- performs atomic list updates without losing the active set on network failure;
- uses a `systemd timer` instead of the old `cron + daemon polling` model.

## Highlights of v3.1

- keeps the v3 atomic `ipset` update and duplicate-rule protections;
- protects the complete JSON configuration read-modify-write cycle with a file lock, so concurrent edits do not lose entries;
- interprets legacy boolean values such as `"false"` safely instead of accidentally enabling GeoIP;
- rejects IPv6 addresses and networks consistently: this release supports IPv4 `ipset` sets only;
- validates the checksum manifest in GitHub Actions and documents checksum verification before publishing;
- expands mock coverage for concurrent configuration edits, boolean normalization, and IPv6 rejection.

## Repository layout

```text
RCN/
├── installer.sh
├── rkn-watcher.sh
├── config_tool.py
├── geoip_apply.py
├── README.ru.md / README.en.md
├── CHANGELOG.ru.md / CHANGELOG.en.md
├── RELEASE_NOTES.ru.md / RELEASE_NOTES.en.md
├── PUBLISHING.ru.md / PUBLISHING.en.md
├── docs/
│   ├── ru/
│   └── en/
└── tests/
```

## Quick start

```bash
git clone https://github.com/Balbuto/RCN.git
cd RCN
chmod +x installer.sh rkn-watcher.sh
sudo ./installer.sh
```

The installer:
- checks that it runs as `root`;
- checks required dependencies;
- installs missing packages;
- launches the main interactive installation flow;
- supports full removal of all managed changes.

## Main commands

### Via installer
```bash
sudo ./installer.sh
sudo ./installer.sh install
sudo ./installer.sh uninstall
sudo ./installer.sh deps
sudo ./installer.sh status
```

### Via main script
```bash
sudo ./rkn-watcher.sh install
sudo ./rkn-watcher.sh update
sudo ./rkn-watcher.sh apply
sudo ./rkn-watcher.sh status
sudo ./rkn-watcher.sh uninstall
```

After installation, the following shortcut is also created:

```bash
sudo rkn-watcher
```

## Supported environment

- Debian 11 / 12
- Ubuntu 20.04 / 22.04 / 24.04
- IPv4 for country-based GeoIP
- `root` privileges are required

## Data sources

- TSPU / Skipa CIDR: `https://github.com/tread-lightly/CyberOK_Skipa_ips`
- GOVIPS / blacklist-v4.ipset: `https://github.com/C24Be/AS_Network_List`
- Country CIDR: `https://www.ipdeny.com/ipblocks/`

## Documentation

- [Installation](docs/en/INSTALL.md)
- [Interactive installer](docs/en/INSTALLER.md)
- [Usage](docs/en/USAGE.md)
- [Configuration](docs/en/CONFIGURATION.md)
- [Migration](docs/en/MIGRATION.md)
- [Troubleshooting](docs/en/TROUBLESHOOTING.md)
- [Security](docs/en/SECURITY.md)

## License

MIT. See [LICENSE](LICENSE).
