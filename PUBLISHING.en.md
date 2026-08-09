# Publishing the release

## 1. Validate before publishing

From the release directory root:

```bash
bash -n installer.sh
bash -n rkn-watcher.sh
python3 -m py_compile config_tool.py geoip_apply.py
chmod +x tests/run_tests.sh
./tests/run_tests.sh
sha256sum -c SHA256SUMS
```

Expected result:
- no Bash syntax errors;
- no Python compilation errors;
- `All tests passed.`;
- every entry in `SHA256SUMS` reports `OK`.

## 2. Initialize a Git repository

```bash
git init
git add .
git commit -m "Release v3.1.0"
```

## 3. Connect to GitHub

```bash
git branch -M main
git remote add origin <YOUR_REPO_URL>
git push -u origin main
```

## 4. Create and push the release tag

```bash
git tag -a v3.1.0 -m "RKN Watcher v3.1.0"
git push origin v3.1.0
```

## 5. What to attach to GitHub Release

Use `RELEASE_NOTES.en.md` or `RELEASE_NOTES.ru.md` as the release description.

Recommended assets:
- `RCN-v3.1.0.tar.gz`
- `RCN-v3.1.0.zip`

## 6. What should not be committed

Do not commit runtime data from a real server:
- `/etc/rkn-watcher/*`
- `/var/log/rkn-watcher/*`
- `/var/lib/rkn-watcher/*`
- systemd unit files copied from an installed machine
- real `iptables` / `ipset` dumps
