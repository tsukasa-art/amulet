---
title: "Troubleshooting"
description: "How to resolve common issues with Amulet, unseal failures, and service startup timeouts."
order: 8
---

## Why unseal produces no output on failure

`unseal` exits with code 1 and no output on any failure — wrong passphrase,
wrong key name, wrong vault path, or machine mismatch. This is intentional:
diagnostic messages would give an attacker who has obtained the vault file
information about *why* decryption failed. See [Security Reference](security.md)
for the full rationale.

The consequence is that a misconfiguration in a startup script looks the same
as a successful run that produces no output. The steps below let you isolate
the cause without exposing secret values.

---

## App won't start / service keeps failing

Run these steps manually as the same user the service runs as.

### Step 1 — Confirm the vault path is correct

```sh
ls -l /path/to/secrets.vault
amulet list --file /path/to/secrets.vault
```

If `list` prints nothing or errors, the path is wrong or the file is
unreadable. Check `--file` in your wrapper script and the file permissions
(`chmod 600`).

### Step 2 — Confirm the key name exists (exact match, case-sensitive)

```sh
amulet list --file /path/to/secrets.vault
```

Key names are matched byte-for-byte. `API_KEY` and `api_key` are different
keys. Compare the output of `list` against the key names used in your wrapper.

### Step 3 — Test the passphrase with `verify`

`verify` decrypts and immediately discards the result — it confirms the
passphrase is correct without printing the secret value:

```sh
# From a passphrase file
cat ~/.config/amulet/passphrase | amulet verify YOUR_KEY --file /path/to/secrets.vault
echo $?   # 0 = passphrase and key are both correct; 1 = something is wrong
```

If `verify` returns 1, the passphrase is wrong. Re-read the passphrase
interactively to make sure it matches what was used at seal time:

```sh
amulet verify --tty YOUR_KEY --file /path/to/secrets.vault
```

### Step 4 — Check for a Locked-mode machine mismatch

If the vault was sealed on a different machine and copied over, Locked mode
will reject it on every unseal. `probe` prints the machine identifier this
host would use:

```sh
amulet probe
```

A Locked vault can only be decrypted on the machine whose identifier was
active when it was sealed. If `probe` returns exit code 2, the machine
identifier cannot be read — this is itself a reason Locked-mode unseal will
fail.

If you need to move a vault to a new machine, see the migration steps in
[Deployment Guide](deployment.md#planned-machine-migration).

---

## Service startup times out (many secrets)

Amulet runs Argon2id (64 MiB, 3 passes) once per `unseal` call. Each call
takes roughly 0.5–1 second on typical VPS hardware. A wrapper that loops over
all keys can take 10–30 seconds for vaults with 15+ entries, which approaches
systemd's default `TimeoutStartSec` (90 s).

If your service fails with `start operation timed out`, add an explicit
timeout to the unit:

```ini
[Service]
TimeoutStartSec=120
```

Adjust the value based on the number of secrets and measured startup time.

---

## Passphrase rotation — changing the passphrase for all keys

`re-seal` changes the passphrase for one key at a time. To rotate the
passphrase across the entire vault, re-seal each key in sequence:

```sh
# List all key names first
amulet list --file ~/.config/amulet/secrets.vault

# Re-seal each key (prompts current passphrase, new passphrase, confirmation)
amulet re-seal KEY_ONE   --file ~/.config/amulet/secrets.vault
amulet re-seal KEY_TWO   --file ~/.config/amulet/secrets.vault
amulet re-seal KEY_THREE --file ~/.config/amulet/secrets.vault
```

There is no single command to rotate all keys at once. For vaults with many
entries, pipe the key list into a loop:

```sh
amulet list --file ~/.config/amulet/secrets.vault | while read -r key; do
  echo "Re-sealing: $key"
  amulet re-seal "$key" --file ~/.config/amulet/secrets.vault
done
```

Each iteration prompts for the current and new passphrase. You will be
prompt once per key — enter the same new passphrase each time.

---

## machine_id changes after sealing (OS reinstall vs. upgrade)

| Event | machine_id | Locked vault |
|-------|-----------|--------------|
| `apt upgrade` / `do-release-upgrade` | Preserved | Continues to work |
| OS reinstall (format + clean install) | New ID generated | **Unrecoverable** |
| VM clone without reinitialising machine-id | Same as source | Decryptable on clone (see [deployment.md](deployment.md)) |

An in-place upgrade (`do-release-upgrade`) keeps `/etc/machine-id` intact.
A clean OS reinstall generates a new `machine_id`, permanently locking out
any Locked vault that was sealed under the old one.

**Mitigation:** keep the original secret values in a separate secure location
(password manager, etc.) so they can be re-sealed after a reinstall.

---

## Quick reference

| Symptom | First check |
|---------|------------|
| Service exits immediately, no log output | `amulet verify` with the same passphrase file |
| `verify` returns 1 | Wrong passphrase, wrong key name, or machine mismatch |
| `verify` returns 0 but app still fails | Key name mismatch between vault and wrapper script |
| Service start times out | Add `TimeoutStartSec=120` to the unit; check key count |
| Unseal worked before, fails after server migration | Run `amulet probe`; vault may be Locked to the old machine |
| Unseal worked before, fails after OS reinstall | Locked vault is unrecoverable; re-seal from original secret values |
