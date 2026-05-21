---
title: "CLI Usage Reference"
description: "A detailed reference of all Amulet commands, flags, and usage patterns."
order: 3
---

## Command quick reference

| Command | Synopsis | Passphrase? |
|---------|----------|-------------|
| `init` | `amulet init [--file <vault>]` | No |
| `seal` | `amulet seal [--portable] <key> [--file <vault>]` | Yes (TTY) |
| `unseal` | `amulet unseal [--tty] <key> [--file <vault>]` | Yes (stdin or TTY) |
| `verify` | `amulet verify [--tty] <key> [--file <vault>]` | Yes (stdin or TTY) |
| `re-seal` | `amulet re-seal <key> [--file <vault>]` | Yes (old + new, TTY) |
| `import` | `amulet import --env-file <path> [--portable] [--manifest <path>] [--wipe] [--wipe-comment] [--file <vault>]` | Yes (TTY) |
| `list` | `amulet list [--file <vault>]` | No |
| `delete` | `amulet delete <key> [--file <vault>]` | No |
| `rename` | `amulet rename <old> <new> [--file <vault>]` | No |
| `probe` | `amulet probe` | No |
| `version` | `amulet version` | No |
| `help` | `amulet help` \| `-h` \| `--help` | No |

`--file <vault>` defaults to `amulet.vault` in the current directory when omitted.

---

## init

```sh
amulet init --file secrets.vault
```

Creates an empty vault file (mode `0600` on Unix). Does not ask for a passphrase. Fails with exit code 1 if the file already exists.

---

## seal

```sh
# Locked Mode (default): binds to this machine's OS-reported identifier
echo -n "your-secret-value" | amulet seal OPENAI_API_KEY --file secrets.vault

# Portable Mode: passphrase only, no machine identifier binding
echo -n "your-secret-value" | amulet seal --portable OPENAI_API_KEY --file secrets.vault
```

- Passphrase is prompted from `/dev/tty` (echo off). The secret comes from **stdin** only — never from argv.
- If the key already exists, the entry is overwritten.
- `--portable` prints a warning to stderr and sets a flag in the vault header that `unseal` reads automatically.

> **Shell history:** `echo 'secret' | …` may leave the secret in shell history. For production, prefer stdin from your CI secret store.
> In bash, prefixing the command with a space suppresses recording when `HISTCONTROL` is set to `ignorespace` or `ignoreboth` — but this is shell-specific and depends on user configuration, not a universal guarantee. The equivalent in zsh is `setopt HIST_IGNORE_SPACE`. For sensitive values, prefer a secret store or file-based source over `echo`. If unsure, run `echo test` in your shell and check `history` to confirm what actually gets recorded.

---

## unseal

```sh
# Interactive: passphrase prompted from /dev/tty with echo off
amulet unseal --tty OPENAI_API_KEY --file secrets.vault

# Script / CI: passphrase from stdin first line
printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault

# Capture to a shell variable
SECRET=$(printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault)
```

- Locked vs Portable mode is **auto-detected** from the vault header — no flag needed on unseal.
- On success: secret written to **stdout** (no trailing newline), exit code 0.
- On any failure: **no output**, exit code 1.

**Checking exit code in scripts:**

```sh
if ! printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault > /dev/null; then
  echo "unseal failed" >&2; exit 1
fi
```

**Unseal prints nothing?** Check in order:
1. **Passphrase** — same as at `seal`, trailing newline included when piping.
2. **Vault path** — `--file` points to the correct file and it exists.
3. **Key name** — exact spelling (case-sensitive). Use `amulet list` to confirm.
4. **Locked mode** — entry was sealed on a machine with the same machine_id. A vault copied to a host with a different machine_id fails.
5. **Exit code** — `echo $?` (Unix) or `echo $LASTEXITCODE` (PowerShell) should be `1`.

---

## verify

```sh
# Passphrase from stdin
printf "mypassphrase\n" | amulet verify OPENAI_API_KEY --file secrets.vault

# Passphrase from /dev/tty with echo off
amulet verify --tty OPENAI_API_KEY --file secrets.vault
```

Decrypts and immediately discards the plaintext — **no output** on success, exit code 0. Exit code 1 on any failure. Useful for CI health checks without exposing the secret value.

---

## re-seal

```sh
amulet re-seal OPENAI_API_KEY --file secrets.vault
```

Prompts for the current passphrase, a new passphrase, and a confirmation — all from `/dev/tty` with echo off. The Locked/Portable mode of the entry is preserved; the re-encrypted blob replaces the original.

---

## import

```sh
# Basic import
amulet import --env-file .env --file secrets.vault

# Write a key-names-only manifest for git
amulet import --env-file .env --file secrets.vault --manifest .env.example

# Wipe .env values after a successful import
amulet import --env-file .env --file secrets.vault --wipe

# Same, plus append a comment line so readers know values were wiped on purpose
amulet import --env-file .env --file secrets.vault --wipe --wipe-comment

# Portable mode
amulet import --env-file .env --file secrets.vault --portable
```

- Reads `KEY=VALUE` lines (blank lines and `#` comments are skipped).
- Existing keys are overwritten.

> **Note:** Quotes and `export KEY=…` syntax are **not** supported.
> A line like `export API_KEY=foo` will be skipped silently — remove the
> `export` prefix before importing.
- The passphrase is prompted once for all entries.

`--manifest <path>` writes one key name per line (truncates if it exists). Commit this file instead of `.env` so teammates know which secrets are required.

`--wipe` overwrites the value portion of each line with spaces after the vault write succeeds. Best-effort — on SSDs, physical erasure is not guaranteed.

`--wipe-comment` may only be used with `--wipe`. After a successful wipe it appends one `# …` line (LF) to the end of the `.env` file if that exact line is not already present — useful so teammates do not mistake wiped values for file corruption. This leaves a small informational trace that Amulet was used.

---

## list

```sh
amulet list --file secrets.vault
```

Prints one key name per line. No passphrase required. Exit code 1 if the vault is missing, unreadable, or corrupt.

---

## delete

```sh
amulet delete OPENAI_API_KEY --file secrets.vault
```

Removes the entry from the vault without a passphrase. Exit code 1 if the key is missing or the vault is invalid.

---

## rename

```sh
amulet rename OLD_KEY_NAME NEW_KEY_NAME --file secrets.vault
```

Renames a key in the vault index without a passphrase and without re-encrypting the blob. Exit code 1 if the old key is missing, the new key already exists, or the vault is invalid.

---

## probe

```sh
amulet probe
```

Prints the machine identifier used for Locked-mode sealing. Useful for troubleshooting cross-machine failures. Exit code 2 if the ID cannot be read.

---

## version / help

```sh
amulet version        # prints the release tag, e.g. v1.0.0
amulet help           # same as -h or --help
```

---

## Node.js / TypeScript

Copy `wrappers/node/amulet.ts` into your project. It spawns `amulet unseal` and passes the result as an opaque `Buffer` to your callback, then zeros it on exit.

```typescript
import { withSecret } from './wrappers/node/amulet';

const passphraseBuf = Buffer.from(process.env.VAULT_PASSPHRASE!, 'utf8');

await withSecret('OPENAI_API_KEY', 'secrets.vault', passphraseBuf, async (secret) => {
  // secret is a Buffer — do not cast to string, do not store outside this callback.
  await callExternalApi(secret);
});
// Buffer is zeroed automatically after the callback returns, even if it throws.
```

Use the `binaryPath` option to specify a non-PATH location for the `amulet` binary.

---

## File naming conventions

| File | Example | Notes |
|------|---------|-------|
| Vault (encrypted) | `secrets.vault`, `prod.vault` | Safe to commit to git. |
| Temporary .env | `.env.tmp`, `.secrets.env` | Add to `.gitignore`. Plaintext briefly exists on disk. |

If you generate a plaintext `.env` as a development bridge, enforce `trap`-based deletion and `.gitignore` registration.
