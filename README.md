# KeePass vault

Приватная база паролей KeePassXC с синхронизацией через git.

- `passwords.kdbx` — единственный источник истины, AES-256/ChaCha20 + Argon2id.
- Удалённый репозиторий: `git@github.com:max-eroshkin/keepass-vault.git` (**private**).
- Устройства: Linux (`~/Vault`), Windows (`%USERPROFILE%\Vault`).

## Правила

1. **Перед работой** — `kp open` (делает pull, открывает базу, после выхода пушит).
2. **Pull только при закрытой базе.** Пока KeePassXC запущен, таймер делает только commit+push.
3. **Никаких force-push и `git reset --hard`.**
4. При расхождении версий — `kp merge` (спрашивает мастер-пароль, объединяет записи).
5. `conflicts/*.kdbx` — временные копии базы, **не коммитятся**, удалять после проверки.

## Команды (Linux)

```bash
kp open      # pull → KeePassXC → commit+push
kp sync      # commit+push (+ ff-pull, если база закрыта)
kp merge     # слить расходящиеся версии
kp status    # состояние: ahead/behind, незакоммиченные правки
```

Таймер: `systemctl --user list-timers | grep keepass`
Логи: `journalctl --user -u keepass-sync -n 50`

## Windows

```powershell
.\tools\kp.ps1 open
.\tools\kp.ps1 sync
.\tools\kp.ps1 status
```

Задание в Task Scheduler каждые 5 минут: `powershell -ExecutionPolicy Bypass -File %USERPROFILE%\Vault\tools\kp.ps1 sync`

## Восстановление

```bash
git log --oneline -- passwords.kdbx        # история версий
git show <sha>:passwords.kdbx > /tmp/restore.kdbx
```

Затем открыть `/tmp/restore.kdbx` в KeePassXC и при необходимости сохранить поверх рабочей базы.

## Безопасность

- История git хранит **все прошлые версии** базы: удалённые/сменённые пароли остаются в старых коммитах.
  Это удобно для восстановления, но помните: «удалено из базы» ≠ «удалено из истории».
- Keyfile не используется — единственный секрет это мастер-пароль. Храните офлайн-копию.
- 2FA на GitHub обязательна: доступ к репозиторию = доступ к шифротексту.
- `.kdbx.lock`, `.kdbx.old`, `conflicts/` исключены через `.gitignore`.
