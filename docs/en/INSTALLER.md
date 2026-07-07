# Interactive installer

File:

```text
installer.sh
```

This is the recommended entry point for installing and removing RKN Watcher.

## What the installer does

### During installation
- checks that it is running as `root`;
- checks compatibility with `apt` / `dpkg`;
- validates required dependencies;
- installs missing packages;
- stores the list of packages that were installed specifically by this installer;
- runs `rkn-watcher.sh install`.

### During removal
- performs full removal of all changes introduced by RKN Watcher;
- can perform emergency cleanup even if the main script is damaged or missing;
- can optionally remove packages that were previously installed by the installer itself.

## Run

```bash
sudo ./installer.sh
```

## Menu entries

1. Install / upgrade RKN Watcher
2. Check dependencies
3. Full removal of all managed changes
4. Show status
0. Exit

## Direct commands

```bash
sudo ./installer.sh install
sudo ./installer.sh uninstall
sudo ./installer.sh deps
sudo ./installer.sh status
```

## Checked dependencies

- `iptables`
- `ipset`
- `curl`
- `ca-certificates`
- `python3`
- `util-linux`

## What is removed during uninstall

- `systemd` units `rkn-watcher-update.timer`, `rkn-watcher-update.service`, `rkn-watcher-boot.service`;
- managed `iptables` chains;
- managed `ipset` sets;
- `/opt/rkn-watcher`
- `/etc/rkn-watcher`
- `/var/lib/rkn-watcher`
- `/var/log/rkn-watcher`
- `/usr/local/bin/rkn-watcher`

After that, the installer may offer to remove packages that it previously installed.
