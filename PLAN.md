# Amulet — Master Plan
Hardware-Bound, Zero-Trace Secret Manager

---

## Vision

Amulet is a CLI tool that encrypts secrets and binds them to a specific physical machine.
No plaintext secrets ever touch disk. No `.env` files. No leak surface for AI agents or
subprocesses. Decryption silently fails on wrong machine, wrong passphrase, or wrong binary.

---

## Milestones

### M1 — Environment Survey (Phase 2)
Verify hardware-ID retrieval on each target OS before touching crypto code.

| OS     | Source                              | Command / API                          |
|--------|-------------------------------------|----------------------------------------|
| Linux  | `/etc/machine-id`                   | `std.fs.File.readAll`                  |
| macOS  | IOPlatformUUID (IOKit registry)     | `IOServiceGetMatchingService` via syscall or shell-out to `ioreg -rd1 -c IOPlatformExpertDevice` |

Deliverable: standalone `probe_id.zig` that prints the trimmed UUID on both platforms and exits non-zero if unavailable.

---

### M2 — Crypto Core (Phase 3a)
File: `src/crypto.zig`

**Key Derivation**
- Algorithm: **Argon2id** (memory-hard, side-channel resistant)
- Locked Mode input: `passphrase ‖ 0x00 ‖ machine_id` + 16-byte random salt from vault header
- Portable Mode input: `passphrase` only + same 16-byte random salt from vault header (machine_id not mixed in)
- Salt: always 16-byte CSPRNG random, generated at `seal` time and stored in vault header — both modes use it
- Parameters (starting point, tunable):
  - `m_cost`: 65536 KiB (64 MiB)
  - `t_cost`: 3 iterations
  - `parallelism`: 1
- Output: 32-byte derived key

**Encryption**
- Algorithm: **ChaCha20-Poly1305** (preferred — constant-time on all platforms, no hardware dependency)
- AES-256-GCM available as compile-time alternative for hardware-AES environments
- Nonce: 12-byte random from `std.crypto.random`
- AAD: vault format version byte (for future-proofing)

**Vault File Format** (binary, fixed layout)

```
[1 byte]  version = 0x01
[1 byte]  flags   (bit 0 = portable mode)
[16 byte] argon2id salt
[12 byte] ChaCha20-Poly1305 nonce
[4 byte]  ciphertext length (big-endian u32)
[N byte]  ciphertext + 16-byte Poly1305 tag
```

**Memory Safety**
- All key material in `[32]u8` stack arrays
- `std.crypto.utils.secureZero` called in `defer` blocks immediately after last use
- No heap allocation for secret material

---

### M3 — CLI (Phase 3b)
File: `src/main.zig`

```
amulet seal   [--portable] <key> [--file <vault>]
amulet unseal               <key> [--file <vault>]
amulet init                      [--file <vault>]
```

**`seal`** — reads secret value from stdin (never argv), encrypts, appends/updates entry in vault. `--portable` sets `flags` bit 0 in vault header.

**`unseal`** — reads `flags` byte from vault header to auto-detect Locked vs Portable mode. No `--portable` flag needed (and not accepted) — the vault itself carries the mode. Decrypts and prints secret to stdout only. Exits with code 1 on any failure (no diagnostic message).

**`init`** — creates an empty vault file with header.

**stdin protocol**: value is read until EOF or `\0`. The raw bytes (no trailing newline) become the plaintext.

**Schema validation** (comptime): `schema.zig` declares a `comptime []const []const u8` of known key names. `amulet unseal <key>` triggers a compile-time check that `<key>` is in the schema — catching typos at build time in consumer code.

> Note: runtime key lookup remains; comptime check is for wrapper code that uses `@field` or hard-coded key literals.

---

### M4 — Integration Wrapper (Phase 4)
File: `wrappers/node/amulet.ts`

TypeScript module that:
1. Spawns `amulet unseal <key>` as a child process
2. Reads stdout (the secret) into a `Buffer`, never a `string`
3. Passes it to the consumer callback / Promise
4. Zeroes the `Buffer` after use (`buf.fill(0)`)
5. Never logs or stringifies the value

No Node.js wrapper has access to the raw key material; it only passes opaque `Buffer` references.

---

## OS Strategy Summary

| Concern              | Linux                        | macOS                          |
|----------------------|------------------------------|--------------------------------|
| Machine ID source    | `/etc/machine-id` (128-bit hex + newline) | `IOPlatformUUID` via `ioreg`  |
| Availability         | Guaranteed on systemd hosts  | Guaranteed on all modern macOS |
| Stability            | Survives reboots, not reinstalls | Survives reboots, not logic board swaps |
| Fallback             | `/var/lib/dbus/machine-id`   | None needed                    |
| Portable mode bypass | `--portable` skips machine-id | Same                          |

---

## Non-Goals
- Windows support (not in scope)
- Network-bound key management (TPM/HSM integration is future work)
- Secret rotation automation
- Multi-user vault sharing
