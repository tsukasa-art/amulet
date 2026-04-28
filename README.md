# Amulet — Hardware-Bound, Zero-Trace Secret Manager

## Overview

Amulet is a CLI tool that encrypts secrets (API keys, tokens, passwords, etc.) and binds them to the **OS-reported machine identifier of the sealing host** (`machine_id` — read from `/etc/machine-id` on Linux, IOPlatformUUID on macOS, MachineGuid on Windows).

- Store secrets in an encrypted vault file — not in `.env` files.
- Secret values are never passed as command-line arguments; they are read from stdin.
- Decryption failure exits silently with code 1, no diagnostic output (by design).
- Designed to reduce accidental leaks to AI coding assistants and other tools.

**New to stdin / stdout / pipes?** See [docs/getting-started.md](docs/getting-started.md).

---

## Why Amulet?

| | Secret management platforms | Amulet |
|---|---|---|
| Setup | Server or cloud account | Single binary |
| Team sharing | ✅ | ❌ Out of scope |
| Network dependency | Yes | None (fully local) |
| Hardware binding | No | ✅ Locked Mode |
| AI agent protection | Indirect | Structurally designed in |

**Good fit:** solo developers, freelancers, AI-assisted / vibe coding workflows, no-server setups.  
**Not a fit:** team secret sharing → use Infisical or Vault. CI/cloud-native → combine with your provider's Secrets Manager.

---

## Installation

Download the latest binary from [GitHub Releases](https://github.com/Tuki-Sana/amulet/releases):

| OS | File |
|---|---|
| Linux (x86_64) | `amulet-linux-x86_64` |
| macOS (Apple Silicon) | `amulet-macos-aarch64` |
| macOS (Intel) | `amulet-macos-x86_64` |
| Windows (x86_64) | `amulet-windows-x86_64.exe` |

**Linux / macOS:**
```sh
# Linux x86_64
chmod +x ./amulet-linux-x86_64
sudo install -m 0755 ./amulet-linux-x86_64 /usr/local/bin/amulet

# macOS Apple Silicon
# chmod +x ./amulet-macos-aarch64
# sudo install -m 0755 ./amulet-macos-aarch64 /usr/local/bin/amulet

# macOS Intel
# chmod +x ./amulet-macos-x86_64
# sudo install -m 0755 ./amulet-macos-x86_64 /usr/local/bin/amulet

amulet version
```

**Windows:** rename to `amulet.exe`, move it to a folder on `PATH`. No `chmod` step needed.

### Install on a production server

You can either download directly on the server or copy from your local machine.

**Option A: download on the server**
```sh
# On the server (Linux x86_64)
curl -fL -o /tmp/amulet \
  https://github.com/Tuki-Sana/amulet/releases/latest/download/amulet-linux-x86_64
sudo install -m 0755 /tmp/amulet /usr/local/bin/amulet
amulet version
```

**Option B: copy from local machine**
```sh
# Local -> server
scp ./amulet-linux-x86_64 user@your-server:/tmp/amulet

# On the server
ssh user@your-server "sudo install -m 0755 /tmp/amulet /usr/local/bin/amulet && amulet version"
```

> **Prerequisites:** familiarity with running commands in a terminal. **New to the terminal?** See [docs/getting-started.md](docs/getting-started.md).

---

## Quick Start

> When working with AI tools (Cursor, Claude Code, etc.), the AI may suggest `.env` patterns — use Amulet instead.

**1. Initialize a vault**

```sh
amulet init --file secrets.vault
```

**2. Store a secret**

```sh
echo -n "your-secret-value" | amulet seal OPENAI_API_KEY --file secrets.vault
# Passphrase is prompted in the terminal (echo off). The secret comes via the pipe.
```

**3. Read a secret**

```sh
# Interactive
amulet unseal --tty OPENAI_API_KEY --file secrets.vault

# Script / CI (passphrase on stdin first line)
printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault

# Python
python3 -c "
import os, subprocess
r = subprocess.run(['amulet','unseal','OPENAI_API_KEY','--file','secrets.vault'],
    input=os.environ['VAULT_PASSPHRASE']+'\n', text=True, capture_output=True, check=True)
print(r.stdout)
"

# Node.js / TypeScript — see wrappers/node/amulet.ts
```

**4. Document key names (instead of `.env.example`)**

```
# Required secrets (values are in secrets.vault)
OPENAI_API_KEY
DATABASE_PASSWORD
```

**5. Commit `secrets.vault` to git. Never create `.env` files.**

### Unseal prints nothing?

Check in order: passphrase (same as at `seal`) → vault path (`--file`) → key name (case-sensitive, `amulet list` confirms) → Locked mode (same machine_id as when sealed?).

---

## Modes

| Mode | Sealed with | Decryptable on |
|------|------------|----------------|
| **Locked** (default) | passphrase + OS machine identifier | Any host with the same machine_id |
| **Portable** (`--portable`) | passphrase only | Any machine |

Use Locked for laptops and production servers. Use Portable for CI runners, containers, and migration. See [docs/security.md](docs/security.md) for KDF details and [docs/deployment.md](docs/deployment.md) for a decision table.

---

## Docs

| Document | Contents |
|----------|----------|
| [docs/usage.md](docs/usage.md) | All commands with flags, examples, and Node.js wrapper |
| [docs/security.md](docs/security.md) | Vault format, crypto spec, threat model |
| [docs/deployment.md](docs/deployment.md) | Locked vs Portable decision table, migration, Docker Compose |
| [docs/deploy-ubuntu.md](docs/deploy-ubuntu.md) | Ubuntu 24.04 LTS production deployment with systemd `LoadCredential` |
| [docs/getting-started.md](docs/getting-started.md) | Terminal, PATH, stdin/stdout — for newcomers |

---

## Build & Test

```sh
zig build -Doptimize=ReleaseSafe   # build
zig build test                      # run unit tests (23 tests)
zig build probe                     # verify machine_id retrieval
```

**Supported OS:** Linux (systemd host), macOS, Windows

---

## Releasing (maintainers)

Pushing a tag matching `v*` triggers the [Release workflow](.github/workflows/release.yml). Step-by-step: [RELEASING.md](RELEASING.md) · [日本語](RELEASING-ja.md).

---

## Project Structure

```
amulet/
├── src/
│   ├── probe_id.zig        # OS-specific machine_id retrieval
│   ├── crypto.zig          # Argon2id + ChaCha20-Poly1305 crypto core
│   └── main.zig            # CLI dispatch and vault I/O
├── docs/
│   ├── usage.md            # CLI reference
│   ├── usage-ja.md
│   ├── security.md         # Vault format, crypto spec, threat model
│   ├── security-ja.md
│   ├── deployment.md       # Deployment, migration, Docker Compose
│   ├── deployment-ja.md
│   ├── getting-started.md  # Terminal basics for newcomers
│   └── getting-started-ja.md
├── wrappers/
│   └── node/
│       └── amulet.ts       # Node.js/TypeScript wrapper
├── PLAN.md
├── CHECKLIST.md
├── RELEASING.md            # maintainer: version tag & GitHub Release
├── RELEASING-ja.md
└── README.md
```
