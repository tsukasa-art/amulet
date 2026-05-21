---
title: "Deployment, Migration, and Docker Compose"
description: "Guidelines for deploying Amulet in various environments, migration strategies, and Docker Compose integration."
order: 5
---

## Locked vs Portable: decision table

| Environment | Recommended mode | Operational notes |
|-------------|-----------------|-------------------|
| Physical machine / fixed VM | **Locked** | Threat model: prevents decryption if only the vault file is exfiltrated to a different host. Does not protect against an attacker who already has a shell on the same machine. |
| VM clone / template | **Locked** | **Uniqueness required:** regenerate `machine-id` on each instance after cloning (e.g. `systemd-machine-id-setup`). Duplicate IDs mean vaults sealed on one instance can be decrypted on any clone with the same ID — intended isolation does not hold. |
| Windows (Sysprep) | **Locked** | `MachineGuid` changes on re-generalization. Seal per node after deployment; do not bake a sealed vault into the golden image. If MachineGuid changes after sealing, the vault becomes unrecoverable — follow the migration steps below. |
| Developer laptop | **Locked** (per person) | Each developer seals on their own machine. |
| CI (GitHub Actions, etc.) | **Portable** | Runner instances change each run — machine_id is unstable. Inject a sufficiently long random passphrase via CI secrets. |
| Containers / Kubernetes | **Portable** | Pod machine_id is often unstable or shared. Passphrase strength and secure secret injection are the primary controls. |
| Migration / recovery | **Portable** | Cross-machine decryption is intentional. |

> **OS reinstall / machine identity change:** Locked vaults become unrecoverable if machine_id changes (e.g. Linux: OS reinstall; macOS: logic board swap; Windows: clean OS install or image restore). Include a recovery procedure in your runbook (see below).

**Team pattern:**
- Production hosts: seal and unseal on the server itself (Locked)
- CI and staging: use your platform's secret injection (GitHub Actions secrets, etc.) or Portable vaults with a strong passphrase
- Never share a Locked vault across machines — each environment seals its own

### Operational deep-dives

#### Locked threat model

Locked mixes the OS-reported machine identifier into the Argon2id password input (`/etc/machine-id` on Linux, `IOPlatformUUID` on macOS, `MachineGuid` in the registry on Windows). This means: if only the vault file reaches an attacker's machine (different machine_id), authenticated decryption fails and the secret is unrecoverable without brute-forcing Argon2id. If the attacker already has a shell on the same host, they can read machine_id and the passphrase from process memory or environment — host-level security is still required.

#### VM clones and machine-id uniqueness

Amulet considers any two hosts with the same machine_id to be the "same machine". On Linux, cloning a VM image without reinitializing the ID is a common deployment mistake. The practical consequence:

- **Duplicate IDs:** vault sealed on instance A can be decrypted on instance B if both share the same machine_id. Environment isolation (e.g. dev vault readable in prod) silently breaks.
- **machine-id changes after sealing:** if the host's machine-id changes after a vault was sealed there (e.g. `systemd-machine-id-setup` runs, or the OS is reinstalled), that vault can no longer be decrypted on that host — same failure mode as an OS reinstall.

**Recommended practice:** for template-based Linux deployments, blank the machine-id in the golden image (`> /etc/machine-id`) so that `systemd-machine-id-setup` runs automatically on first boot, giving each instance a unique ID before any sealing happens.

#### CI/CD with Portable mode

In ephemeral environments (GitHub Actions, GitLab CI, Buildkite, etc.) machine_id changes with every runner. Use Portable mode and inject the passphrase from your CI secret store. The passphrase is the sole cryptographic control, so treat it like a long random key — 32+ characters from a CSPRNG is a reasonable baseline.

---

## Migration and disaster recovery

### Vault file copy ≠ recoverable backup for Locked vaults

| Backup type | Contents | Recoverable on a host with a different machine_id? |
|-------------|----------|----------------------------------------------------|
| Vault file copy | Encrypted binary | ❌ Locked: requires matching machine_id |
| Plaintext unsealed on old machine | Raw secret value | ✅ Re-seal on new machine |
| Portable vault copy | Encrypted binary | ✅ Passphrase alone is sufficient |

> **Note:** VM clones sharing the same machine_id can decrypt each other's Locked vaults. See the [VM clones note in docs/security.md](security.md) for details.

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

> **Optional — reduce disk exposure (Linux):** On Linux, `mktemp -p /dev/shm` is a good option when `/dev/shm` exists (tmpfs-backed on most distros). In an interactive desktop session where `$XDG_RUNTIME_DIR` is set, `mktemp -p "$XDG_RUNTIME_DIR"` is another common pattern — omit the fallback to `/tmp`, as `/tmp` is not always tmpfs and would defeat the purpose. Either way this is best-effort: swap or storage configuration can affect whether plaintext truly stays off disk. On macOS `/dev/shm` is not available; the default `mktemp` is fine there.

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
