# Installation

## System requirements

Supported systems:
- Debian 11 / 12
- Ubuntu 20.04 / 22.04 / 24.04

Required:
- root access;
- `systemd`;
- internet access for the initial list download.

## Recommended method

```bash
git clone https://github.com/Balbuto/RCN.git
cd RCN
chmod +x installer.sh rkn-watcher.sh
sudo ./installer.sh
```

The interactive `installer.sh`:
1. checks that it is running as `root`;
2. checks required dependencies;
3. installs missing packages;
4. launches the main interactive installation flow in `rkn-watcher.sh`.

The main script then:
1. creates directories under `/opt`, `/etc`, `/var/lib`, and `/var/log`;
2. copies `rkn-watcher.sh`, `config_tool.py`, and `geoip_apply.py` into `/opt/rkn-watcher`;
3. creates the `rkn-watcher` command in `/usr/local/bin`;
4. creates `systemd` units for restore and auto-update;
5. downloads `TSPUBLOCK` and `GOVIPS`;
6. applies `iptables` / `ipset` rules.

## What is created on the system

### Executables
- `/opt/rkn-watcher/rkn-watcher.sh`
- `/opt/rkn-watcher/config_tool.py`
- `/opt/rkn-watcher/geoip_apply.py`
- `/usr/local/bin/rkn-watcher`

### Configuration
- `/etc/rkn-watcher/settings.conf`
- `/etc/rkn-watcher/whitelist.json`
- `/etc/rkn-watcher/blacklist.json`

### State and cache
- `/var/lib/rkn-watcher/cache/`
- `/var/lib/rkn-watcher/state/`
- `/var/lib/rkn-watcher/locks/`

### Logs
- `/var/log/rkn-watcher/update.log`
- `/var/log/rkn-watcher/actions.log`
- `/var/log/rkn-watcher/geoip.log`

## First start

```bash
sudo rkn-watcher
```

Or check the status:

```bash
sudo rkn-watcher status
```

## Updating an installed version

```bash
cd RCN
sudo ./installer.sh install
```

## Installing without git

Download these files into one directory:
- `installer.sh`
- `rkn-watcher.sh`
- `config_tool.py`
- `geoip_apply.py`

Then run:

```bash
chmod +x installer.sh rkn-watcher.sh
sudo ./installer.sh
```

## Removal

```bash
sudo ./installer.sh uninstall
```

Or:

```bash
sudo rkn-watcher uninstall
```

Only managed changes are removed.
