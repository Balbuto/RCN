# Публикация релиза

## 1. Проверка перед публикацией

Из корня релизной папки:

```bash
bash -n installer.sh
bash -n rkn-watcher.sh
python3 -m py_compile config_tool.py geoip_apply.py
chmod +x tests/run_tests.sh
./tests/run_tests.sh
sha256sum -c SHA256SUMS
```

Ожидаемый результат:
- bash-синтаксис без ошибок;
- Python-компиляция без ошибок;
- `All tests passed.`;
- каждая запись в `SHA256SUMS` имеет статус `OK`.

## 2. Инициализация Git-репозитория

```bash
git init
git add .
git commit -m "Release v3.1.0"
```

## 3. Привязка к GitHub

```bash
git branch -M main
git remote add origin <YOUR_REPO_URL>
git push -u origin main
```

## 4. Создание тега релиза

```bash
git tag -a v3.1.0 -m "RKN Watcher v3.1.0"
git push origin v3.1.0
```

## 5. Что приложить в GitHub Release

Рекомендуется использовать содержимое `RELEASE_NOTES.ru.md` или `RELEASE_NOTES.en.md` как описание релиза.

Можно приложить архивы:
- `RCN-v3.1.0.tar.gz`
- `RCN-v3.1.0.zip`

## 6. Что не нужно коммитить

Не включайте в репозиторий runtime-данные с сервера:
- `/etc/rkn-watcher/*`
- `/var/log/rkn-watcher/*`
- `/var/lib/rkn-watcher/*`
- systemd unit-файлы с уже установленной машины
- реальные дампы `iptables` / `ipset`
