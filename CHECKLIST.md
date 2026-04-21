# Amulet — Implementation Checklist

Security and correctness items to verify at each commit. Check off as implemented; reopen if
a refactor touches the relevant code.

---

## Memory Safety

- [x] All secret buffers are stack-allocated `[N]u8` arrays — no heap allocation for key material
- [x] Every secret buffer has a `defer std.crypto.utils.secureZero(u8, &buf)` immediately after declaration
- [x] `secureZero` is called on: passphrase input, machine-id bytes, derived key (+ kdf_input), plaintext before free after decryption
- [x] No `const` binding holds a secret value past its required scope (prevents compiler alias optimizations from skipping the zero)
- [x] `std.crypto.random.bytes` used for nonce and salt generation — never a counter or timestamp

---

## Error Handling & Silent Failure

- [x] All decryption errors (`AuthenticationFailed`, wrong machine, file not found, etc.) produce **no** stderr output and exit with code **1**
- [x] `seal` errors (disk full, permission denied) may print a generic message ("seal failed: …") but **never** include the secret, key name, or derived key in the message
- [x] `std.debug.panic` and `unreachable` paths are audited — none occur on attacker-controlled input
- [x] No error union payload containing key material is ever formatted with `{any}` or `{s}`

---

## No Leakage

- [x] `std.log` is not used anywhere — no info/debug log output in any build mode
- [x] Vault file path is not echoed back in decryption error messages
- [x] Machine-ID value is never printed, logged, or included in any user-visible output
- [x] Argon2id salt is not printed or exposed outside the vault file header
- [x] `amulet unseal` writes the secret **only** to stdout (fd 1), not stderr (fd 2)

---

## KDF Parameters

- [x] Argon2id `m_cost` = 65536 KiB (64 MiB) — resists GPU attacks
- [x] Argon2id `t_cost` = 3 — resists time-memory trade-off attacks
- [x] Salt is 16 bytes of CSPRNG output (stored in vault header) — never hardcoded in either mode
- [x] In `--portable` mode, the same 16-byte CSPRNG salt (from vault header) is used for Argon2id; machine_id is simply not mixed into the KDF input; vault header `flags` bit 0 is set
- [x] Derived key is exactly 32 bytes

---

## Encryption Correctness

- [x] Nonce is 12 bytes of CSPRNG output — **never reused** across `seal` calls (new random nonce each time)
- [x] Poly1305 tag (16 bytes) is verified atomically before any plaintext byte is returned (`ChaCha20Poly1305.decrypt` is an AEAD)
- [x] AAD (version byte) is authenticated — a vault from a different format version fails authentication
- [x] Vault format version byte is checked before attempting decryption
- [x] Ciphertext length field is validated against `max_plaintext_len` (64 KiB) before allocation

---

## Machine-ID Binding

- [x] Machine-ID is trimmed of whitespace/newlines before use as KDF input (`std.mem.trim` on Linux; UUID extracted directly on macOS)
- [x] On Linux: try `/etc/machine-id` first, fallback to `/var/lib/dbus/machine-id`; if both missing, exit with code 1 (no silent fallback to a weak value)
- [x] On macOS: UUID parsed from `ioreg` output; if parsing fails, exit with code 1
- [x] Machine-ID is concatenated with passphrase as `passphrase ‖ 0x00 ‖ machine_id` (null separator prevents length-extension confusion)
- [x] Machine-ID bytes are zeroed after KDF call (zeroed as part of `kdf_input` in `deriveKey` and in `main.zig` caller)

---

## CLI & Input Handling

- [x] Secret value is **only** read from stdin — never from argv, env vars, or files
- [x] Key name (argv) does not appear in the vault ciphertext — it is stored as a plaintext entry index, outside the crypto blob
- [x] `--portable` flag on `seal` is logged as a warning to stderr: "WARNING: portable mode reduces security"
- [x] `unseal` reads `flags` byte from vault header to determine mode automatically — no `--portable` flag accepted on `unseal`
- [x] `unseal` rejects unknown `flags` bits (future-proofing) rather than silently ignoring them
- [x] Vault file is opened with `O_NOFOLLOW` to prevent symlink attacks
- [x] Vault file permissions are set to `0600` on creation (both `init` and atomic temp file in `seal`)

---

## Build & Release

- [x] Release build uses `-Doptimize=ReleaseSafe` (not `ReleaseFast`) to retain safety checks; enforced via CI and release workflow
- [ ] `std.builtin.mode` assertion: panic if built in `Debug` mode and `--portable` is not set (dev guard) — **skipped**: cost to development workflow outweighs benefit; ReleaseSafe enforced via CI and README instead
- [x] Strip debug symbols in release: `-Dstrip=true` via `build.zig` option; applied in release workflow (`release.yml`)
- [x] CI runs `zig build test` on Linux, macOS, and Windows runners (`.github/workflows/ci.yml`)

---

## Integration Wrapper (Node.js)

- [x] Secret is kept as `Buffer`, never cast to `string`
- [x] `Buffer.fill(0)` is called in `finally` block after consumer callback returns (zeroed even if callback throws)
- [x] Child process stdout is consumed with a size limit (64 KiB) to prevent OOM on malformed vault
- [x] Child process stderr is discarded (not logged)
- [x] Wrapper never accepts the secret as a string parameter or returns it as a string

---

## Threat Model Reference

| Threat                          | Mitigation                                      |
|---------------------------------|-------------------------------------------------|
| AI agent reads env vars         | No `.env` — secrets only in vault file          |
| Process list / argv sniffing    | Secret read from stdin, not argv                |
| Vault copied to another machine | Argon2id binds to machine-ID in Locked Mode     |
| Weak passphrase                 | Argon2id stretching with high memory cost       |
| Cold-boot / memory dump         | `secureZero` after use; no heap allocation      |
| Log injection / exfiltration    | No logging of secret material; silent failure   |
| Symlink attack on vault file    | `O_NOFOLLOW` on open                            |
| Nonce reuse                     | Fresh CSPRNG nonce per `seal` call              |
