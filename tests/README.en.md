# Tests

This folder contains a small set of safe mock tests that validate `iptables` / `ipset` logic without touching the real server firewall.

## What is covered

### For `rkn-watcher.sh`
- correct creation of `TSPUBLOCK` and `GOVIPS` rules;
- no duplicate hook rules in `INPUT`;
- successful `ipset` population on update;
- proper failure return on list download errors;
- preservation of the previous working `ipset` set after a failed update;
- cleanup of managed chains and sets via `remove_managed_firewall()`.

### For `geoip_apply.py`
- creation of `GEOIP_ALLOW_IPS`, `GEOIP_DENY_IPS`, and `GEOIP_COUNTRIES_ALLOW`;
- correct construction of `RKN_GEOIP_HOOK` and `GEOIP_DROP` chains;
- no duplicated `INPUT` hook on repeated apply;
- cleanup of hook and chains when `enabled=false`.

## Run

From the repository root:

```bash
chmod +x tests/run_tests.sh
./tests/run_tests.sh
```

## Requirements

- `bash`
- `python3`
- normal user execution is fine
- root is not required

## Note

These are not kernel-level firewall integration tests. They validate script logic through mock implementations of `iptables`, `ipset`, `curl`, and related commands.
