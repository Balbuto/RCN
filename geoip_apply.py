#!/usr/bin/env python3
import ipaddress
import json
import logging
import os
import subprocess
import sys
import time
import urllib.request

CONFIG_FILE = "/etc/rkn-watcher/whitelist.json"
BLACKLIST_FILE = "/etc/rkn-watcher/blacklist.json"
SETTINGS_FILE = "/etc/rkn-watcher/settings.conf"
CACHE_DIR = "/var/lib/rkn-watcher/cache/countries"
LOG_FILE = "/var/log/rkn-watcher/geoip.log"

COUNTRY_CACHE_TTL = 24 * 3600
RULE_COMMENT = "rkn-watcher-geoip-hook"
HOOK_CHAIN = "RKN_GEOIP_HOOK"
ACTION_CHAIN = "GEOIP_DROP"
ALLOW_IP_SET = "GEOIP_ALLOW_IPS"
DENY_IP_SET = "GEOIP_DENY_IPS"
COUNTRY_SET = "GEOIP_COUNTRIES_ALLOW"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", filename=LOG_FILE)


def run(cmd, check=True, capture=False, input_data=None):
    result = subprocess.run(
        cmd,
        input=input_data,
        text=True,
        capture_output=capture,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(cmd)}\n{result.stderr}")
    return result


def remove_input_jump():
    while True:
        result = subprocess.run(
            ["iptables", "-C", "INPUT", "-m", "comment", "--comment", RULE_COMMENT, "-j", HOOK_CHAIN],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode != 0:
            break
        run(["iptables", "-D", "INPUT", "-m", "comment", "--comment", RULE_COMMENT, "-j", HOOK_CHAIN], check=False)


def ensure_chain(name: str):
    subprocess.run(["iptables", "-N", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    run(["iptables", "-F", name], check=False)


def ensure_ipset(name: str, set_type: str = "hash:net", maxelem: int = 2000000):
    run(["ipset", "create", name, set_type, "family", "inet", "maxelem", str(maxelem), "-exist"], check=True)


def replace_set(name: str, entries, set_type: str = "hash:net", maxelem: int = 2000000):
    temp_name = f"{name}_TMP"
    subprocess.run(["ipset", "destroy", temp_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    lines = [f"create {temp_name} {set_type} family inet maxelem {maxelem} -exist", f"flush {temp_name}"]
    count = 0
    for entry in entries:
        lines.append(f"add {temp_name} {entry}")
        count += 1
    run(["ipset", "restore"], input_data="\n".join(lines) + "\n")
    ensure_ipset(name, set_type=set_type, maxelem=maxelem)
    run(["ipset", "swap", temp_name, name])
    subprocess.run(["ipset", "destroy", temp_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return count


def chunked(values, size=15):
    for index in range(0, len(values), size):
        yield values[index:index + size]


def load_settings():
    data = {"FILTER_PORTS": "all"}
    if not os.path.exists(SETTINGS_FILE):
        return data
    with open(SETTINGS_FILE, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.strip()
            if not line or "=" not in line:
                continue
            key, value = line.split("=", 1)
            data[key] = value.strip().strip('"')
    return data


def load_json(path, default):
    if not os.path.exists(path):
        return default
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        return default
    merged = dict(default)
    merged.update(data)
    return merged


def normalize_ip_list(values):
    result = []
    for value in values:
        if "/" in str(value):
            result.append(str(ipaddress.ip_network(str(value), strict=False)))
        else:
            result.append(str(ipaddress.ip_address(str(value))))
    return sorted(set(result))


def normalize_port_list(values):
    return sorted({int(v) for v in values if 1 <= int(v) <= 65535})


def normalize_country_list(values):
    result = []
    for value in values:
        code = str(value).strip().upper()
        if len(code) != 2 or not code.isalpha():
            raise ValueError(f"Invalid country code: {value}")
        result.append(code)
    return sorted(set(result))


def parse_filter_ports(raw_value: str):
    raw_value = (raw_value or "all").strip()
    if raw_value == "all":
        return "all"
    ports = []
    for part in raw_value.split(','):
        part = part.strip()
        if not part:
            continue
        port = int(part)
        if port < 1 or port > 65535:
            raise ValueError(f"Invalid filter port: {part}")
        ports.append(port)
    return sorted(set(ports))


def fetch_country_entries(country_code: str):
    os.makedirs(CACHE_DIR, exist_ok=True)
    cache_path = os.path.join(CACHE_DIR, f"{country_code.lower()}.zone")
    now = time.time()
    content = None
    if os.path.exists(cache_path) and now - os.path.getmtime(cache_path) < COUNTRY_CACHE_TTL:
        with open(cache_path, "r", encoding="utf-8") as fh:
            content = fh.read()
    else:
        url = f"https://www.ipdeny.com/ipblocks/data/aggregated/{country_code.lower()}-aggregated.zone"
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                content = response.read().decode("utf-8")
            with open(cache_path, "w", encoding="utf-8") as fh:
                fh.write(content)
        except Exception:
            if os.path.exists(cache_path):
                with open(cache_path, "r", encoding="utf-8") as fh:
                    content = fh.read()
            else:
                raise
    entries = []
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith('#'):
            continue
        network = ipaddress.ip_network(line, strict=False)
        if network.version == 4:
            entries.append(str(network))
    if not entries:
        raise RuntimeError(f"No IPv4 CIDRs for {country_code}")
    return entries


def build_country_set(country_codes):
    entries = set()
    for code in country_codes:
        for item in fetch_country_entries(code):
            entries.add(item)
    return sorted(entries)


def apply_geoip():
    settings = load_settings()
    whitelist = load_json(CONFIG_FILE, {"enabled": False, "countries": [], "ips": [], "ports": []})
    blacklist = load_json(BLACKLIST_FILE, {"ips": [], "ports": []})

    enabled = bool(whitelist.get("enabled", False))
    whitelist_ips = normalize_ip_list(whitelist.get("ips", []))
    blacklist_ips = normalize_ip_list(blacklist.get("ips", []))
    whitelist_ports = normalize_port_list(whitelist.get("ports", []))
    blacklist_ports = normalize_port_list(blacklist.get("ports", []))
    countries = normalize_country_list(whitelist.get("countries", []))
    filter_ports = parse_filter_ports(settings.get("FILTER_PORTS", "all"))

    replace_set(ALLOW_IP_SET, whitelist_ips, set_type="hash:net", maxelem=65536)
    replace_set(DENY_IP_SET, blacklist_ips, set_type="hash:net", maxelem=65536)
    country_entries = build_country_set(countries) if countries else []
    replace_set(COUNTRY_SET, country_entries, set_type="hash:net", maxelem=3000000)

    ensure_chain(HOOK_CHAIN)
    ensure_chain(ACTION_CHAIN)
    remove_input_jump()

    if not enabled:
        logging.info("GeoIP filtering disabled")
        print("GeoIP filtering disabled")
        return 0

    if filter_ports == "all":
        run(["iptables", "-A", HOOK_CHAIN, "-j", ACTION_CHAIN])
    else:
        for port in filter_ports:
            run(["iptables", "-A", HOOK_CHAIN, "-p", "tcp", "--dport", str(port), "-j", ACTION_CHAIN])
        run(["iptables", "-A", HOOK_CHAIN, "-j", "RETURN"])

    if blacklist_ips:
        run(["iptables", "-A", ACTION_CHAIN, "-m", "set", "--match-set", DENY_IP_SET, "src", "-j", "DROP"])
    if whitelist_ips:
        run(["iptables", "-A", ACTION_CHAIN, "-m", "set", "--match-set", ALLOW_IP_SET, "src", "-j", "RETURN"])

    for chunk in chunked(blacklist_ports):
        run(["iptables", "-A", ACTION_CHAIN, "-p", "tcp", "-m", "multiport", "--dports", ",".join(str(p) for p in chunk), "-j", "DROP"])
    for chunk in chunked(whitelist_ports):
        run(["iptables", "-A", ACTION_CHAIN, "-p", "tcp", "-m", "multiport", "--dports", ",".join(str(p) for p in chunk), "-j", "RETURN"])

    if countries:
        run(["iptables", "-A", ACTION_CHAIN, "-m", "set", "--match-set", COUNTRY_SET, "src", "-j", "RETURN"])
        run(["iptables", "-A", ACTION_CHAIN, "-j", "DROP"])
    else:
        run(["iptables", "-A", ACTION_CHAIN, "-j", "RETURN"])

    run(["iptables", "-I", "INPUT", "1", "-m", "comment", "--comment", RULE_COMMENT, "-j", HOOK_CHAIN])
    logging.info(
        "GeoIP applied: countries=%s allow_ips=%s deny_ips=%s allow_ports=%s deny_ports=%s filter_ports=%s",
        len(countries), len(whitelist_ips), len(blacklist_ips), len(whitelist_ports), len(blacklist_ports),
        "all" if filter_ports == "all" else len(filter_ports)
    )
    print("GeoIP rules applied")
    return 0


def status():
    result = run(["iptables", "-L", HOOK_CHAIN, "-v", "-n"], check=False, capture=True)
    print(result.stdout)
    result = run(["iptables", "-L", ACTION_CHAIN, "-v", "-n"], check=False, capture=True)
    print(result.stdout)
    for set_name in (ALLOW_IP_SET, DENY_IP_SET, COUNTRY_SET):
        result = run(["ipset", "list", set_name], check=False, capture=True)
        print(result.stdout)
    return 0


def main(argv):
    if len(argv) < 2:
        print("Usage: geoip_apply.py [apply|status]", file=sys.stderr)
        return 1
    cmd = argv[1]
    if cmd == "apply":
        return apply_geoip()
    if cmd == "status":
        return status()
    print(f"Unknown command: {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
