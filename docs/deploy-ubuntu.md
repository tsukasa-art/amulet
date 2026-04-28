# Amulet — Ubuntu Production Deployment (systemd)

This guide covers deploying Amulet on Ubuntu 24.04 LTS (systemd 255) using
`LoadCredential` to inject the vault passphrase without exposing it in the
environment or on the command line.

> **Target:** Ubuntu 22.04+ (systemd 247+). Ubuntu 20.04 (systemd 245) does
> not support `LoadCredential` — see the [Ubuntu 20.04 fallback](#ubuntu-2004-fallback).

---

## Why `LoadCredential`

`LoadCredential` mounts the passphrase as a tmpfs file inside
`$CREDENTIALS_DIRECTORY` for the duration of the service process. The
credential is never passed as a command-line argument or stored in the process
environment, and it is cleaned up automatically when the service stops.

The unsealed secret is exported as an environment variable for the application
process. On Linux, root can read process environment variables via
`/proc/<pid>/environ`. This is expected server-level behaviour; host access
control (non-root app user, `PermitRootLogin no`) remains necessary.

---

## 1. Harden SSH

Before placing any secrets on the server, confirm these settings in
`/etc/ssh/sshd_config`:

```
PermitRootLogin no
PasswordAuthentication no
```

> **Warning:** Open a second SSH session as your sudo user before reloading,
> to avoid locking yourself out.

```sh
sudo systemctl reload ssh
```

---

## 2. Place the vault file

Copy your `secrets.vault` to the server and set ownership so only the app
user can read it:

```sh
sudo mkdir -p /etc/amulet
sudo cp secrets.vault /etc/amulet/secrets.vault
sudo chown root:myapp /etc/amulet/secrets.vault
sudo chmod 640 /etc/amulet/secrets.vault
```

Replace `myapp` with the system user that runs your application.

---

## 3. Store the passphrase

Write the passphrase to a root-only file. Avoid shell history exposure by
reading from stdin. `printf "%s"` writes no trailing newline, which avoids
a passphrase mismatch when `amulet unseal` reads the credential file:

```sh
sudo mkdir -p /etc/amulet
sudo bash -c 'read -rs PASS && printf "%s" "$PASS" > /etc/amulet/passphrase'
sudo chmod 600 /etc/amulet/passphrase
sudo chown root:root /etc/amulet/passphrase
```

---

## 4. Create a startup wrapper

This script unseals the secrets and launches the application with them
available as environment variables. Use the full path to `amulet` so the
script is not sensitive to systemd's `PATH`:

```sh
# /usr/local/bin/myapp-start.sh
#!/bin/sh
export API_KEY=$(cat "$CREDENTIALS_DIRECTORY/amulet-pass" \
  | /usr/local/bin/amulet unseal API_KEY --file /etc/amulet/secrets.vault)
exec /opt/myapp/bin/myapp
```

Set ownership so `myapp` can execute it via the group bit:

```sh
sudo chown root:myapp /usr/local/bin/myapp-start.sh
sudo chmod 750 /usr/local/bin/myapp-start.sh
```

Add one `export` line per secret your application needs.

---

## 5. Create the systemd service

```ini
# /etc/systemd/system/myapp.service
[Unit]
Description=My App
After=network.target

[Service]
User=myapp
LoadCredential=amulet-pass:/etc/amulet/passphrase
ExecStart=/usr/local/bin/myapp-start.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now myapp
sudo systemctl status myapp
```

---

## Security summary

| Control | Effect |
|---------|--------|
| `chmod 600` on passphrase file | Only root can read it |
| `LoadCredential` | Passphrase lands in tmpfs; cleaned up on service stop |
| `chown root:myapp 750` on wrapper | Only root and `myapp` group can execute it |
| `User=myapp` | Application runs as a non-root user |
| Locked vault (default) | Vault is bound to this machine's `machine_id`; unreadable on another host |
| `PermitRootLogin no` | Root cannot log in directly over SSH |
| `PasswordAuthentication no` | SSH key required; brute-force password attacks are blocked |

---

## Physical server: stronger option with TPM2

On bare-metal servers that have a TPM2 chip, `LoadCredentialEncrypted` binds
the passphrase to the TPM so the file is unreadable on any other machine.
Use the same stdin-based approach as step 3 to avoid shell history exposure:

```sh
sudo bash -c 'read -rs PASS && printf "%s" "$PASS" \
  | systemd-creds encrypt --name=amulet-pass - /etc/amulet/passphrase.cred'
sudo chmod 600 /etc/amulet/passphrase.cred
```

Change the service unit:

```ini
LoadCredentialEncrypted=amulet-pass:/etc/amulet/passphrase.cred
```

> VPS environments typically do not expose a TPM2 chip. Use plain
> `LoadCredential` on VPS.

---

## Ubuntu 20.04 fallback

Ubuntu 20.04 ships systemd 245, which predates `LoadCredential`. This is a
last-resort option — **upgrading to 22.04+ and using `LoadCredential` is
strongly preferred.**

`xargs -I{}` is fragile when secrets contain spaces, quotes, or newlines. Use
this pattern only for single-line secrets such as API keys:

```ini
[Service]
ExecStart=/bin/sh -c 'cat /etc/amulet/passphrase \
  | /usr/local/bin/amulet unseal API_KEY --file /etc/amulet/secrets.vault \
  | xargs -I{} env API_KEY={} /opt/myapp/bin/myapp'
```

> Ubuntu 20.04 reached end-of-life in April 2025. Upgrading to 24.04 LTS is
> strongly recommended.

---

## See also

- [docs/deployment.md](deployment.md) — Locked vs Portable decision table, migration, Docker Compose
- [docs/security.md](security.md) — vault format, crypto spec, threat model
