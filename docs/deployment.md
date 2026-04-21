# Amulet — Deployment, Migration, and Docker Compose

## Locked vs Portable: decision table

| Environment | Recommended mode | Reason |
|-------------|-----------------|--------|
| Production fixed server | **Locked** | Stable machine_id; vault can be copied but not decrypted on another machine |
| Developer laptop | **Locked** (per person) | Each developer seals on their own machine |
| CI (GitHub Actions, etc.) | **Portable** | Runner instances change each run — machine_id is unstable |
| Containers / Kubernetes | **Portable** | Pod machine_id is often unstable |
| Migration / recovery | **Portable** | Cross-machine decryption is intentional |

> **OS reinstall / hardware replacement:** Locked vaults become unrecoverable if machine_id changes. Include a recovery procedure in your runbook (see below).

**Team pattern:**
- Production hosts: seal and unseal on the server itself (Locked)
- CI and staging: use your platform's secret injection (GitHub Actions secrets, etc.) or Portable vaults with a strong passphrase
- Never share a Locked vault across machines — each environment seals its own

---

## Migration and disaster recovery

### Vault file copy ≠ recoverable backup for Locked vaults

| Backup type | Contents | Recoverable on another machine? |
|-------------|----------|--------------------------------|
| Vault file copy | Encrypted binary | ❌ Locked: requires matching machine_id |
| Plaintext unsealed on old machine | Raw secret value | ✅ Re-seal on new machine |
| Portable vault copy | Encrypted binary | ✅ Passphrase alone is sufficient |

### Planned machine migration

While the old machine is still running:

```sh
# 1. Extract on the old machine
printf "mypassphrase\n" | amulet unseal SECRET_KEY --file secrets.vault

# 2. Re-seal on the new machine (Locked binds to the new machine_id)
echo -n "<extracted value>" | amulet seal SECRET_KEY --file secrets.vault
```

### Sudden machine failure

If the old machine is unbootable, a Locked vault **cannot be recovered**. Prepare in advance:
- Keep secrets in a separate secure location (password manager, etc.)
- Or maintain a Portable vault as an offline backup

### Multi-device development

The same Locked vault cannot be shared across devices. Choose one of:
- **Separate vault per device** — each device seals its own (independent Locked vaults)
- **Shared Portable vault** — share the passphrase securely, use the same vault everywhere
- **Portable for development, Locked for production** — mix modes per environment

---

## Docker Compose / Podman Compose

The most reliable approach is to write the secret to a **short-lived temp file** and pass it with `--env-file`.

### Step-by-step

**1. Create a temp file and register cleanup:**

```sh
TMP_ENV=$(mktemp)
chmod 0600 "$TMP_ENV"
trap "rm -f '$TMP_ENV'" EXIT
```

> **Optional — memory-backed temp file (Linux):** To avoid the plaintext ever touching disk, use `mktemp -p /dev/shm` or `mktemp -p "${XDG_RUNTIME_DIR:-/tmp}"`. `/dev/shm` is not available on macOS; use the default `mktemp` there.

**2. Write one `KEY=value` line.** Use two commands — some zsh versions do not merge stdout from subshell redirections reliably:

```sh
printf 'OPENAI_API_KEY=' > "$TMP_ENV"
printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault >> "$TMP_ENV"
```

On **bash**, a subshell one-liner also works:

```sh
( printf 'OPENAI_API_KEY='; printf "mypassphrase\n" | amulet unseal OPENAI_API_KEY --file secrets.vault ) > "$TMP_ENV"
```

If `wc -c "$TMP_ENV"` equals only the `OPENAI_API_KEY=` prefix, `unseal` did not append — check passphrase, key name, `--file`, or Locked-mode machine mismatch.

**3. Run Compose:**

```sh
docker compose --env-file "$TMP_ENV" config   # dry-run
docker compose --env-file "$TMP_ENV" up

# Podman
podman compose --env-file "$TMP_ENV" up
```

**4. Teardown:**

```sh
docker compose down
rm -f "$TMP_ENV"    # or just exit the shell (trap handles it)
```

If you run `compose down` without `--env-file`, Compose may warn that `OPENAI_API_KEY` is unset — harmless for removal.

### Podman on macOS

If `podman compose` cannot connect, start the VM: `podman machine start` (run `podman machine init` once first).

### `$` escaping in Compose YAML

Compose interpolates `$VAR` / `${VAR}` in YAML strings. In `command:` blocks, use `$$` so the container shell receives a literal `$` (e.g. `$$OPENAI_API_KEY`). Avoid bash-only expansions like `${#VAR}` — Compose treats them as invalid interpolation.

> **Note:** The temporary file briefly holds plaintext on disk. Always use `trap` to ensure deletion. In production, prefer CI secret injection over temp files.
