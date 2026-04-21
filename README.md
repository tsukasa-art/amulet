# Amulet — Hardware-Bound, Zero-Trace Secret Manager

## Overview

Amulet is a CLI tool that encrypts secrets (API keys, tokens, passwords, etc.) and binds them to a **specific physical machine**.

- No `.env` files
- Secrets never touch argv or environment variables (stdin only)
- Decryption failures exit silently with code 1 — no diagnostic output
- Structurally prevents secret leakage to AI agents and subprocesses

---

## Modes

### Locked Mode (default)

The vault can only be decrypted on the machine that sealed it.

```
KDF input = Argon2id(passphrase ‖ 0x00 ‖ machine_id, salt)
```

- Linux: `/etc/machine-id` (fallback: `/var/lib/dbus/machine-id`)
- macOS: `IOPlatformUUID` (via `ioreg`)

### Portable Mode (seal with `--portable`)

machine_id is not mixed into the KDF. Intended for migration and verification use cases.

```
KDF input = Argon2id(passphrase, salt)
```

- `flags` bit 0 in the vault header is set to 1
- `unseal` auto-detects the mode from the header — no `--portable` flag needed
- A warning is printed to stderr on seal because security is reduced

---

## Vault File Format (binary)

```
[1 byte]  version  = 0x01
[1 byte]  flags    (bit 0 = portable mode)
[16 byte] Argon2id salt  (CSPRNG random, generated per seal)
[12 byte] ChaCha20-Poly1305 nonce (CSPRNG random, generated per seal)
[4 byte]  ciphertext length (big-endian u32)
[N byte]  ciphertext + 16-byte Poly1305 authentication tag
```

---

## Crypto Spec

| Item | Spec |
|------|------|
| KDF | Argon2id (m=64MiB, t=3, p=1) |
| Encryption | ChaCha20-Poly1305 |
| Key length | 256 bit (32 bytes) |
| Salt | 16-byte CSPRNG (stored in vault header) |
| Nonce | 12-byte CSPRNG (stored in vault header, never reused) |
| AAD | version byte (format change detection) |

---

## CLI Usage

### Initialize

```sh
amulet init --file secrets.vault
```

Creates an empty vault file.

### Write a secret (seal)

```sh
# Locked Mode (default): passphrase prompted from /dev/tty, secret from stdin
echo -n "sk-xxxxxxxx" | amulet seal OPENAI_API_KEY --file secrets.vault

# Portable Mode: add --portable flag (warning printed to stderr)
echo -n "sk-xxxxxxxx" | amulet seal --portable OPENAI_API_KEY --file secrets.vault
```

> `seal` reads the passphrase from `/dev/tty` (echo off). The secret comes from stdin only.

### Read a secret (unseal)

Reads the first line of stdin as the passphrase. Locked vs Portable mode is auto-detected from the vault header.

**Interactive input** (using from a terminal)

```sh
# --tty: passphrase prompted from /dev/tty with echo off (same as seal)
amulet unseal --tty OPENAI_API_KEY --file secrets.vault

# without --tty: reads stdin first line as-is (no prompt, no echo off)
amulet unseal OPENAI_API_KEY --file secrets.vault
```

> Without `--tty`, the passphrase is echoed to the terminal when typed. Use `--tty` for interactive use.

**Pipe input** (for scripts and CI)

```sh
# pass passphrase via pipe
printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault

# assign to a shell variable
SECRET=$(printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault)
```

> In CI, use your platform's secret injection (e.g. GitHub Actions secrets) instead of `printf`. Manual `export` in a terminal leaves the passphrase in shell history — avoid it.

**Checking exit code in scripts**

```sh
if ! printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault > /dev/null; then
  echo "unseal failed" >&2
  exit 1
fi
```

- On success: secret written to stdout (no trailing newline)
- On failure: no output, exits with code 1 (no diagnostic message)

### Node.js / TypeScript

```typescript
import { withSecret } from './wrappers/node/amulet';

// The guiding principle for passphrase delivery is: avoid leak-prone paths.
// CI/CD secret injection (e.g. GitHub Actions secrets) is acceptable.
// Manual `export` in a terminal or writing to a .env file stays in shell history
// and AI tool context — avoid both.
const passphraseBuf = Buffer.from(process.env.VAULT_PASSPHRASE!, 'utf8');

await withSecret('OPENAI_API_KEY', 'secrets.vault', passphraseBuf, async (secret) => {
  // secret is a Buffer, valid only inside this callback.
  // Do not cast to string.
  await callExternalApi(secret);
});
// The secret Buffer is zeroed automatically after the callback completes.
// Zeroing is guaranteed even if the callback throws.
```

> Use the `binaryPath` option of `withSecret` to specify the path to the `amulet` binary (defaults to PATH lookup).

---

## File Naming Conventions

| File | Example names | Notes |
|------|---------------|-------|
| vault (encrypted binary) | `secrets.vault`, `prod.vault` | `*.vault` extension recommended. Safe to commit to git. |
| temporary .env (dev bridge) | `.env.tmp`, `.secrets.env` | Always add to `.gitignore`. Be aware that plaintext briefly exists on disk. |

`*.vault` files are encrypted binaries and safe to commit to git.  
If you generate a plaintext `.env`, treat it as a development bridge only — enforce `trap`-based deletion and `.gitignore` registration.

---

## Docker Compose / Podman Compose Integration

The most reliable way to integrate a vault into a Compose-based workflow is via a **temporary file**.

```sh
TMP_ENV=$(mktemp)
chmod 0600 "$TMP_ENV"
trap "rm -f '$TMP_ENV'" EXIT

printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault > "$TMP_ENV"

docker compose --env-file "$TMP_ENV" up
# For Podman: podman compose --env-file "$TMP_ENV" up
```

> **Note:** The temporary file briefly holds plaintext on disk. Treat it as a development bridge and always use `trap` to ensure deletion. In production, use CI secret injection instead.

Process substitution (`<(amulet unseal …)`) also works but is bash-specific and may behave differently across Compose versions and environments — the temporary file approach above is preferred (advanced users only).

---

## Deployment Guide: Locked vs Portable

Locked Mode binds a vault to a single machine — strong isolation, but requires deliberate design in multi-environment setups.

| Environment | Recommended mode | Reason |
|-------------|-----------------|--------|
| Production fixed server | **Locked** | Stable machine_id; vault cannot be decrypted elsewhere |
| Developer laptop | **Locked** (per person) | Each developer seals on their own machine |
| CI (GitHub Actions, etc.) | **Portable** | Runner instances change each run — machine_id is unstable |
| Containers / Kubernetes | **Portable** | Pod machine_id is often unstable |
| Migration / verification | **Portable** | Cross-machine decryption is intentional |

> **Note on OS reinstall / hardware replacement:** Locked vaults become unrecoverable if machine_id changes (Linux: OS reinstall; macOS: logic board swap). Include a recovery procedure in your runbook.

**Team usage pattern**

The simplest approach that scales well:

- Production hosts: seal and unseal on the server itself (Locked)
- CI and staging: use your platform's secret injection (GitHub Actions secrets, etc.) or Portable vaults with a strong passphrase
- Never share a Locked vault across machines — each environment seals its own

---

## Security Design Principles

| Principle | Description |
|-----------|-------------|
| No .env Policy | No plaintext writes to disk — not even for development |
| Silent Failure | Decryption failure: no diagnostic output, exit code 1 only |
| No Leakage | Logs and errors never contain secrets, machine_id, or key material |
| Immediate Erasure | `std.crypto.utils.secureZero` zeroes memory immediately after use |
| Stdin Only | Secrets are never received via argv or environment variables |

---

## Build & Test

```sh
# Build (ReleaseSafe recommended)
zig build -Doptimize=ReleaseSafe

# Verify machine-ID retrieval
zig build probe

# Run all unit tests
zig build test
```

**Supported OS:** Linux (systemd host), macOS

---

## Project Structure

```
amulet/
├── src/
│   ├── probe_id.zig   # Phase 2: OS-specific machine-ID retrieval
│   ├── crypto.zig     # Phase 3a: Argon2id + ChaCha20-Poly1305 crypto core
│   ├── main.zig       # Phase 3b: CLI (seal / unseal / init)
│   └── schema.zig     # comptime key name validation
├── wrappers/
│   └── node/
│       └── amulet.ts  # Phase 4: Node.js/TypeScript wrapper
├── PLAN.md
├── CHECKLIST.md
└── README.md
```
