---
title: "Rootless Deployment (user systemd)"
description: "How to deploy Amulet under a non-root user service using systemctl --user for rootless applications."
order: 7
---

This guide covers deploying Amulet under a **non-root user service**
(`systemctl --user`) — the right choice when your application already runs
rootless (e.g. rootless Podman, a user-owned process manager).

> **Use [Ubuntu Production Deployment](deploy-ubuntu.md) instead** if your app runs
> as a dedicated system user under a root-owned service
> (`/etc/systemd/system`). That guide uses `LoadCredential` and is suitable
> for most server deployments.

---

## When to use this guide

| Scenario | Guide to use |
|----------|-------------|
| App runs as a system user under `/etc/systemd/system` | [deploy-ubuntu.md](deploy-ubuntu.md) |
| App runs rootless (rootless Podman, user process) | **This guide** |
| App runs in Docker / Podman with root daemon | [deploy-ubuntu.md](deploy-ubuntu.md) or [Deployment Guide](deployment.md) |

Mixing a root-owned service with rootless Podman containers commonly causes
permission conflicts. If your containers run as a regular user, keep the
systemd service in user space too.

---

## Prerequisites

- Ubuntu 22.04+ (or any Linux with systemd 247+; user services work on older
  versions too — only `LoadCredential` requires 247+)
- `amulet` binary installed — see [Installation](getting-started)
- Your application already runs correctly as the target user

---

## 1. Place the amulet binary

Install to the user's local bin directory so no `sudo` is needed:

```sh
curl -fL -o /tmp/amulet https://github.com/tsukasa-art/amulet/releases/latest/download/amulet-linux-x86_64
chmod +x /tmp/amulet
mkdir -p ~/.local/bin
install -m 0755 /tmp/amulet ~/.local/bin/amulet
~/.local/bin/amulet version
```

Add `~/.local/bin` to `PATH` if not already present:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

> **Use the full path in scripts.** `systemd --user` services run with a
> minimal `PATH` that does not include `~/.local/bin`. Always write
> `/home/youruser/.local/bin/amulet` (or `$HOME` equivalent) in wrapper
> scripts, never just `amulet`.

---

## 2. Create the vault from your .env file

```sh
mkdir -p ~/.config/amulet

amulet import \
  --env-file /path/to/your/.env \
  --file ~/.config/amulet/secrets.vault

chmod 600 ~/.config/amulet/secrets.vault
```

Verify the import:

```sh
amulet list --file ~/.config/amulet/secrets.vault
```

> **`.env` format requirement:** `import` expects plain `KEY=VALUE` lines.
> Lines starting with `export` (e.g. `export API_KEY=foo`) are **not**
> supported — remove the `export` prefix before importing.

After confirming the vault is correct, wipe the plaintext:

```sh
# Option A: wipe in place (replaces values with blank lines)
amulet import --env-file /path/to/your/.env \
  --file ~/.config/amulet/secrets.vault --wipe

# Option B: delete the file entirely
rm /path/to/your/.env
```

---

## 3. Store the passphrase

Write the passphrase to a user-only file. `printf "%s"` writes no trailing
newline, which avoids a mismatch when `amulet unseal` reads the file:

```sh
bash -c 'read -rsp "Amulet passphrase: " PASS; echo; printf "%s" "$PASS" > ~/.config/amulet/passphrase'
chmod 600 ~/.config/amulet/passphrase
```

Confirm the file looks right (should be one line with no trailing newline):

```sh
wc -c ~/.config/amulet/passphrase
```

---

## 4. Consolidate to one vault location

If a `secrets.vault` exists elsewhere in the project directory, retire it so
there is exactly one canonical file:

```sh
# Move project-local copy to a backup name; the service will use ~/.config/amulet/secrets.vault
mv ~/myapp/secrets.vault ~/myapp/secrets.vault.bak
```

Having two vault files with the same name in different directories is a common
source of confusion — updates applied to one leave the other stale.

---

## 5. Create a startup wrapper

The wrapper unseals all secrets and exports them before launching the app.
Use absolute paths throughout — user services inherit a minimal `PATH`.

```sh
cat > ~/.local/bin/myapp-start.sh <<'EOF'
#!/bin/bash
set -euo pipefail

VAULT="$HOME/.config/amulet/secrets.vault"
PASSPHRASE_FILE="$HOME/.config/amulet/passphrase"

# Unseal all keys and export them
while IFS= read -r key; do
  value="$(cat "$PASSPHRASE_FILE" | /home/youruser/.local/bin/amulet unseal "$key" --file "$VAULT")"
  export "$key=$value"
done < <(/home/youruser/.local/bin/amulet list --file "$VAULT")

# Launch the application
exec /path/to/your/app
EOF

chmod 750 ~/.local/bin/myapp-start.sh
```

Replace `/home/youruser` with the actual home directory path (not `~` or
`$HOME`, since `ExecStart=` in systemd does not expand those).

---

## 6. Create the user service

```sh
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/myapp.service <<'EOF'
[Unit]
Description=My App (rootless)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/youruser/myapp
ExecStart=/home/youruser/.local/bin/myapp-start.sh

[Install]
WantedBy=default.target
EOF
```

Load and start:

```sh
systemctl --user daemon-reload
systemctl --user enable myapp
systemctl --user start myapp
systemctl --user status myapp --no-pager -l
```

---

## 7. Enable linger (auto-start on boot)

User services only start automatically after login by default. Enable linger
so the service starts at boot even when no one is logged in:

```sh
loginctl enable-linger "$USER"
```

Confirm:

```sh
loginctl show-user "$USER" | grep Linger
# Expected: Linger=yes
```

Test by rebooting and checking the application is up before you log in.

---

## 8. Verify

```sh
systemctl --user status myapp
# confirm your app is reachable, e.g.:
curl -fsS http://127.0.0.1/your-health-endpoint
```

---

## Updating secrets after deployment

### Normal update (interactive)

```sh
echo -n "new_secret_value" | \
  amulet seal SECRET_KEY --file ~/.config/amulet/secrets.vault

systemctl --user restart myapp
```

### When SSH may disconnect (bulk update via temp file)

Interactive `seal` over SSH can be interrupted mid-input if the connection
drops. For bulk updates or long-running operations, use a temp file instead:

```sh
# Write new values to a temp file (never commit this file)
cat > /tmp/amulet-update.env <<'EOF'
SECRET_KEY=new_value
ANOTHER_KEY=another_value
EOF

amulet import \
  --env-file /tmp/amulet-update.env \
  --file ~/.config/amulet/secrets.vault \
  < ~/.config/amulet/passphrase

rm -f /tmp/amulet-update.env

systemctl --user restart myapp
```

> Delete `/tmp/amulet-update.env` immediately after import. `/tmp` is
> world-readable by default on most Linux systems.

---

## Security summary

| Control | Effect |
|---------|--------|
| `chmod 600` on vault and passphrase | Only the owning user can read them |
| Full path to `amulet` in scripts | Immune to `PATH` manipulation |
| `loginctl enable-linger` | Service starts at boot; does not require interactive login |
| Locked vault (default) | Vault is bound to this machine's `machine_id`; unreadable on another host |
| Single canonical vault path (`~/.config/amulet/`) | No stale copies diverging silently |
| `/proc/<pid>/environ` note | Root on the same host can read exported env vars — host-level access control is still required |

---

## See also

- [Ubuntu Production Deployment](deploy-ubuntu.md) — root service with `LoadCredential` (system user, no rootless requirement)
- [Deployment Guide](deployment.md) — Locked vs Portable decision table, migration, Docker Compose
- [Security Reference](security.md) — vault format, crypto spec, threat model
