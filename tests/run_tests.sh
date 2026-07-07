#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

extract_bash_lib() {
    python3 - "$REPO_ROOT/rkn-watcher.sh" "$TMP_ROOT/rkn-lib.sh" <<'PY'
from pathlib import Path
src = Path(__import__('sys').argv[1]).read_text()
marker = '\nmain "$@"\n'
idx = src.rfind(marker)
if idx == -1:
    raise SystemExit('failed to locate main invocation')
Path(__import__('sys').argv[2]).write_text(src[:idx] + '\n')
PY
}

create_fake_iptables() {
    cat > "$1" <<'PY'
#!/usr/bin/env python3
import json, os, sys
state_file = os.path.join(os.environ['STATE'], 'iptables.json')
os.makedirs(os.path.dirname(state_file), exist_ok=True)
if os.path.exists(state_file):
    with open(state_file) as f:
        st = json.load(f)
else:
    st = {'chains': {'INPUT': []}}
st['chains'].setdefault('INPUT', [])
args = sys.argv[1:]
rc = 0
out = ''
def save():
    with open(state_file, 'w') as f:
        json.dump(st, f)
def rule(parts):
    return ' '.join(parts)
if args[0] == '-N':
    st['chains'].setdefault(args[1], [])
elif args[0] == '-F':
    st['chains'].setdefault(args[1], [])
    st['chains'][args[1]] = []
elif args[0] == '-X':
    ch = args[1]
    if st['chains'].get(ch):
        rc = 1
    else:
        st['chains'].pop(ch, None)
elif args[0] in ('-A', '-I'):
    ch = args[1]
    st['chains'].setdefault(ch, [])
    rest = args[2:]
    if args[0] == '-I' and rest and rest[0].isdigit():
        pos = int(rest[0])
        rest = rest[1:]
        st['chains'][ch].insert(max(pos - 1, 0), rule(rest))
    elif args[0] == '-I':
        st['chains'][ch].insert(0, rule(rest))
    else:
        st['chains'][ch].append(rule(rest))
elif args[0] in ('-C', '-D'):
    ch = args[1]
    rest = rule(args[2:])
    rules = st['chains'].setdefault(ch, [])
    if rest in rules:
        if args[0] == '-D':
            rules.remove(rest)
    else:
        rc = 1
elif args[0] == '-L':
    ch = args[1]
    if ch not in st['chains']:
        rc = 1
    else:
        out = '\n'.join(st['chains'][ch])
save()
if out:
    print(out)
sys.exit(rc)
PY
    chmod +x "$1"
}

create_fake_ipset() {
    cat > "$1" <<'PY'
#!/usr/bin/env python3
import json, os, sys
state_file = os.path.join(os.environ['STATE'], 'ipset.json')
os.makedirs(os.path.dirname(state_file), exist_ok=True)
if os.path.exists(state_file):
    with open(state_file) as f:
        st = json.load(f)
else:
    st = {}
args = sys.argv[1:]
rc = 0
out = ''
def save():
    with open(state_file, 'w') as f:
        json.dump(st, f)
if args[0] == 'create':
    st.setdefault(args[1], [])
elif args[0] == 'list':
    if len(args) == 1:
        out = '\n'.join(st)
    else:
        name = args[1]
        if name not in st:
            rc = 1
        else:
            out = f'Name: {name}\nNumber of entries: {len(st[name])}\n'
elif args[0] == 'add':
    st.setdefault(args[1], [])
    if args[2] not in st[args[1]]:
        st[args[1]].append(args[2])
elif args[0] == 'save':
    if len(args) == 1:
        for name, vals in st.items():
            print(f'create {name} hash:net family inet maxelem 1000')
            for v in vals:
                print(f'add {name} {v}')
        sys.exit(0)
    name = args[1]
    if name in st:
        print(f'create {name} hash:net family inet maxelem 1000')
        for v in st[name]:
            print(f'add {name} {v}')
    sys.exit(0)
elif args[0] == 'restore':
    for line in sys.stdin.read().splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == 'create':
            st.setdefault(parts[1], [])
        elif parts[0] == 'flush':
            st[parts[1]] = []
        elif parts[0] == 'add':
            st.setdefault(parts[1], [])
            if parts[2] not in st[parts[1]]:
                st[parts[1]].append(parts[2])
elif args[0] == 'swap':
    st.setdefault(args[1], [])
    st.setdefault(args[2], [])
    st[args[1]], st[args[2]] = st[args[2]], st[args[1]]
elif args[0] == 'destroy':
    st.pop(args[1], None)
save()
if out:
    print(out, end='')
sys.exit(rc)
PY
    chmod +x "$1"
}

create_fake_curl() {
    cat > "$1" <<'PY'
#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
out = None
url = None
i = 0
opts_with_value = {'-o', '--output', '--connect-timeout', '--max-time', '--retry', '--retry-delay'}
while i < len(args):
    if args[i] in opts_with_value:
        if args[i] in {'-o', '--output'}:
            out = args[i + 1]
        i += 2
    elif args[i].startswith('-'):
        i += 1
    else:
        url = args[i]
        i += 1
if os.environ.get('MOCK_CURL_FAIL') == '1':
    sys.exit(22)
content = ''
if url and 'skipa_cidr.txt' in url:
    content = '1.1.1.0/24\n2.2.2.0/24\n'
elif url and 'blacklist-v4.ipset' in url:
    content = 'add blacklist-v4 3.3.3.0/24\nadd blacklist-v4 4.4.4.0/24\n'
if out:
    with open(out, 'w') as f:
        f.write(content)
sys.exit(0)
PY
    chmod +x "$1"
}

create_fake_netfilter_persistent() {
    cat > "$1" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$1"
}

run_bash_logic_tests() {
    local root="$TMP_ROOT/bash"
    local bin="$root/bin"
    export STATE="$root/state"
    mkdir -p "$bin" "$STATE" "$root/logs" "$root/install" "$root/etc" "$root/data/statefiles" "$root/data/locks"

    create_fake_iptables "$bin/iptables"
    create_fake_ipset "$bin/ipset"
    create_fake_curl "$bin/curl"
    create_fake_netfilter_persistent "$bin/netfilter-persistent"
    export PATH="$bin:$PATH"

    # shellcheck disable=SC1090
    source "$TMP_ROOT/rkn-lib.sh"

    INSTALL_DIR="$root/install"
    CONFIG_DIR="$root/etc"
    DATA_DIR="$root/data"
    CACHE_DIR="$DATA_DIR/cache"
    COUNTRY_CACHE_DIR="$CACHE_DIR/countries"
    STATE_DIR="$DATA_DIR/statefiles"
    LOCK_DIR="$DATA_DIR/locks"
    LOG_DIR="$root/logs"
    SETTINGS_FILE="$CONFIG_DIR/settings.conf"
    WHITELIST_FILE="$CONFIG_DIR/whitelist.json"
    BLACKLIST_FILE="$CONFIG_DIR/blacklist.json"
    IPSET_STATE_FILE="$STATE_DIR/ipset.conf"
    UPDATE_LOCK_FILE="$LOCK_DIR/update.lock"
    UPDATE_LOG="$LOG_DIR/update.log"
    ACTION_LOG="$LOG_DIR/actions.log"
    GEOIP_LOG="$LOG_DIR/geoip.log"

    cat > "$SETTINGS_FILE" <<'EOF2'
FILTER_PORTS="all"
LOG_RST="n"
AUTO_UPDATE="y"
ENABLE_TSPUBLOCK="y"
ENABLE_GOVIPS="y"
EOF2

    setup_tspublock_rules
    setup_tspublock_rules
    setup_govips_rules
    setup_govips_rules
    python3 - <<'PY'
import json, os
state = json.load(open(os.path.join(os.environ['STATE'], 'iptables.json')))
input_rules = state['chains']['INPUT']
assert input_rules.count('-j TSPUBLOCK') == 1, input_rules
assert input_rules.count('-j GOVBLOCK') == 1, input_rules
assert state['chains']['TSPUBLOCK'] == ['-p tcp --tcp-flags RST RST -m set --match-set TSPUIPS src -j DROP']
assert state['chains']['GOVBLOCK'] == ['-p tcp --tcp-flags RST RST -m set --match-set GOVIPS src -j DROP']
print('OK: setup rules do not duplicate INPUT hooks')
PY

    update_tspublock_list >/dev/null
    update_govips_list >/dev/null
    python3 - <<'PY'
import json, os
state = json.load(open(os.path.join(os.environ['STATE'], 'ipset.json')))
assert sorted(state['TSPUIPS']) == ['1.1.1.0/24', '2.2.2.0/24']
assert sorted(state['GOVIPS']) == ['3.3.3.0/24', '4.4.4.0/24']
print('OK: successful updates populate ipset sets')
PY

    python3 - <<'PY'
import json, os
path = os.path.join(os.environ['STATE'], 'ipset.json')
state = json.load(open(path))
state['TSPUIPS'] = ['9.9.9.0/24']
json.dump(state, open(path, 'w'))
PY
    export MOCK_CURL_FAIL=1
    if update_tspublock_list >/dev/null 2>&1; then
        echo 'FAIL: update_tspublock_list returned success on download error' >&2
        return 1
    fi
    unset MOCK_CURL_FAIL
    python3 - <<'PY'
import json, os
state = json.load(open(os.path.join(os.environ['STATE'], 'ipset.json')))
assert state['TSPUIPS'] == ['9.9.9.0/24']
print('OK: failed update returns error and preserves old set')
PY

    set_setting ENABLE_TSPUBLOCK n >/dev/null
    set_setting ENABLE_GOVIPS n >/dev/null
    setup_tspublock_rules
    setup_govips_rules
    python3 - <<'PY'
import json, os
state = json.load(open(os.path.join(os.environ['STATE'], 'iptables.json')))
assert '-j TSPUBLOCK' not in state['chains']['INPUT']
assert '-j GOVBLOCK' not in state['chains']['INPUT']
assert state['chains']['TSPUBLOCK'] == []
assert state['chains']['GOVBLOCK'] == []
print('OK: disabling clears TSPUBLOCK/GOVIPS hooks and chains')
PY

    set_setting ENABLE_TSPUBLOCK y >/dev/null
    set_setting ENABLE_GOVIPS y >/dev/null
    setup_tspublock_rules
    setup_govips_rules
    python3 - <<'PY'
import json, os
ipt_path = os.path.join(os.environ['STATE'], 'iptables.json')
ipset_path = os.path.join(os.environ['STATE'], 'ipset.json')
ipt = json.load(open(ipt_path))
ipsets = json.load(open(ipset_path))
ipt['chains']['INPUT'].insert(0, '-m comment --comment rkn-watcher-geoip-hook -j RKN_GEOIP_HOOK')
ipt['chains']['RKN_GEOIP_HOOK'] = ['-j GEOIP_DROP']
ipt['chains']['GEOIP_DROP'] = ['-j DROP']
ipsets['GEOIP_ALLOW_IPS'] = ['1.1.1.1']
ipsets['GEOIP_DENY_IPS'] = ['2.2.2.2']
ipsets['GEOIP_COUNTRIES_ALLOW'] = ['5.5.5.0/24']
json.dump(ipt, open(ipt_path, 'w'))
json.dump(ipsets, open(ipset_path, 'w'))
PY
    remove_managed_firewall
    python3 - <<'PY'
import json, os
ipt = json.load(open(os.path.join(os.environ['STATE'], 'iptables.json')))
for token in ['-j TSPUBLOCK', '-j GOVBLOCK', '-m comment --comment rkn-watcher-geoip-hook -j RKN_GEOIP_HOOK']:
    assert token not in ipt['chains']['INPUT'], ipt['chains']['INPUT']
for chain in ['TSPUBLOCK', 'GOVBLOCK', 'RKN_GEOIP_HOOK', 'GEOIP_DROP']:
    assert chain not in ipt['chains'] or ipt['chains'][chain] == []
ipsets = json.load(open(os.path.join(os.environ['STATE'], 'ipset.json')))
for name in ['TSPUIPS', 'GOVIPS', 'GEOIP_ALLOW_IPS', 'GEOIP_DENY_IPS', 'GEOIP_COUNTRIES_ALLOW']:
    assert name not in ipsets
print('OK: remove_managed_firewall removes hooks, chains and sets')
PY
}

run_geoip_tests() {
    local root="$TMP_ROOT/geoip"
    mkdir -p "$root/bin" "$root/state" "$root/etc" "$root/cache/countries" "$root/log"
    export STATE="$root/state"

    create_fake_iptables "$root/bin/iptables"
    create_fake_ipset "$root/bin/ipset"
    export PATH="$root/bin:$PATH"

    python3 - "$REPO_ROOT/geoip_apply.py" "$root/geoip_apply.py" "$root" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
root = sys.argv[3]
replacements = {
    'CONFIG_FILE = "/etc/rkn-watcher/whitelist.json"': f'CONFIG_FILE = r"{root}/etc/whitelist.json"',
    'BLACKLIST_FILE = "/etc/rkn-watcher/blacklist.json"': f'BLACKLIST_FILE = r"{root}/etc/blacklist.json"',
    'SETTINGS_FILE = "/etc/rkn-watcher/settings.conf"': f'SETTINGS_FILE = r"{root}/etc/settings.conf"',
    'CACHE_DIR = "/var/lib/rkn-watcher/cache/countries"': f'CACHE_DIR = r"{root}/cache/countries"',
    'LOG_FILE = "/var/log/rkn-watcher/geoip.log"': f'LOG_FILE = r"{root}/log/geoip.log"',
}
for old, new in replacements.items():
    src = src.replace(old, new)
Path(sys.argv[2]).write_text(src)
PY

    cat > "$root/etc/settings.conf" <<'EOF2'
FILTER_PORTS="443,80"
EOF2
    cat > "$root/etc/whitelist.json" <<'EOF2'
{
  "enabled": true,
  "countries": ["FI"],
  "ips": ["1.1.1.1", "10.0.0.0/24"],
  "ports": [22, 443]
}
EOF2
    cat > "$root/etc/blacklist.json" <<'EOF2'
{
  "ips": ["2.2.2.2"],
  "ports": [25]
}
EOF2
    echo '5.5.5.0/24' > "$root/cache/countries/fi.zone"

    python3 "$root/geoip_apply.py" apply >/dev/null
    python3 - <<'PY'
import json, os
root = os.path.join(os.environ['STATE'], 'iptables.json')
state = json.load(open(root))
assert state['chains']['INPUT'].count('-m comment --comment rkn-watcher-geoip-hook -j RKN_GEOIP_HOOK') == 1
assert state['chains']['RKN_GEOIP_HOOK'] == ['-p tcp --dport 80 -j GEOIP_DROP', '-p tcp --dport 443 -j GEOIP_DROP', '-j RETURN']
action = state['chains']['GEOIP_DROP']
assert action[0] == '-m set --match-set GEOIP_DENY_IPS src -j DROP'
assert '-m set --match-set GEOIP_COUNTRIES_ALLOW src -j RETURN' in action
assert action[-1] == '-j DROP'
sets = json.load(open(os.path.join(os.environ['STATE'], 'ipset.json')))
assert sorted(sets['GEOIP_ALLOW_IPS']) == ['1.1.1.1', '10.0.0.0/24']
assert sets['GEOIP_DENY_IPS'] == ['2.2.2.2']
assert sets['GEOIP_COUNTRIES_ALLOW'] == ['5.5.5.0/24']
print('OK: geoip apply creates expected rules and sets')
PY

    python3 "$root/geoip_apply.py" apply >/dev/null
    python3 - <<'PY'
import json, os
state = json.load(open(os.path.join(os.environ['STATE'], 'iptables.json')))
assert state['chains']['INPUT'].count('-m comment --comment rkn-watcher-geoip-hook -j RKN_GEOIP_HOOK') == 1
print('OK: geoip reapply does not duplicate INPUT hook')
PY

    cat > "$root/etc/whitelist.json" <<'EOF2'
{
  "enabled": false,
  "countries": ["FI"],
  "ips": ["1.1.1.1"],
  "ports": [22]
}
EOF2
    python3 "$root/geoip_apply.py" apply >/dev/null
    python3 - <<'PY'
import json, os
state = json.load(open(os.path.join(os.environ['STATE'], 'iptables.json')))
assert '-m comment --comment rkn-watcher-geoip-hook -j RKN_GEOIP_HOOK' not in state['chains']['INPUT']
assert state['chains']['RKN_GEOIP_HOOK'] == []
assert state['chains']['GEOIP_DROP'] == []
print('OK: disabling geoip clears hook and chains')
PY
}

main() {
    extract_bash_lib
    run_bash_logic_tests
    run_geoip_tests
    echo
    echo 'All tests passed.'
}

main "$@"
