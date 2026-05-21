---
title: "Stopping Use of Amulet"
description: "How to safely export your secrets and remove Amulet from a project or machine."
order: 9
---

This page covers how to safely export your secrets and remove Amulet from a project or machine.

> **Locked mode warning:** A Locked vault can only be decrypted on the machine where it was sealed. If you wipe the machine or change its OS before exporting, the secrets become permanently unrecoverable. Export first, then clean up.

---

## Step 1 — Export your secrets

List all key names stored in the vault, then unseal each one.

```sh
amulet list --file secrets.vault
```

Unseal a single key interactively:

```sh
amulet unseal --tty MY_KEY --file secrets.vault
```

### Batch export to a file

The script below writes every key as `KEY=value` into a plaintext file. Treat that file the same way you would any file containing raw secrets — restrict permissions, delete it when you are done.

```sh
VAULT=secrets.vault
OUTPUT=exported-secrets.env

# Create the file with restricted permissions before writing any secrets
install -m 0600 /dev/null "$OUTPUT"

printf "Enter vault passphrase: "
read -rs PASSPHRASE
echo

while IFS= read -r KEY; do
  VALUE=$(printf '%s\n' "$PASSPHRASE" | amulet unseal "$KEY" --file "$VAULT")
  printf '%s=%s\n' "$KEY" "$VALUE" >> "$OUTPUT"
done < <(amulet list --file "$VAULT")

echo "Exported to $OUTPUT"
```

On **Windows (PowerShell)**, unseal each key individually and paste the values where needed — the batch script above is bash-only.

---

## Step 2 — Migrate to your destination

Where to put the exported secrets depends on what replaces Amulet.

| Destination | What to do |
|-------------|-----------|
| **`.env` file** | Copy `KEY=value` lines from `exported-secrets.env` directly. Add `.env` to `.gitignore`. |
| **Password manager** (1Password, Bitwarden, etc.) | Create a new item per secret and paste the value. |
| **CI secrets** (GitHub Actions, GitLab CI, etc.) | Add each key via the platform's secret settings UI or CLI. |
| **Cloud secrets manager** (AWS Secrets Manager, GCP Secret Manager, HashiCorp Vault) | Use the provider's CLI or SDK to create entries from the exported values. |
| **Another machine with Amulet** | Re-seal on the new machine (`echo -n "<value>" | amulet seal KEY --file secrets.vault`). See [Deployment Guide](deployment.md#planned-machine-migration). |

### Update your code

Search the codebase for any calls to `amulet unseal` and replace them with the mechanism used by your new destination (reading from `.env`, SDK calls, etc.).

```sh
grep -r "amulet" .
```

---

## Step 3 — Clean up

**Delete the vault file:**

```sh
rm secrets.vault
```

If the vault file is committed to git, remove it from history — it contains encrypted data but there is no reason to keep it:

```sh
git rm secrets.vault
git commit -m "remove amulet vault"
```

**Remove the binary:**

```sh
# Linux / macOS (installed to /usr/local/bin)
sudo rm /usr/local/bin/amulet

# If installed elsewhere, check with:
which amulet
```

On **Windows**, delete `amulet.exe` from wherever you placed it and remove that directory from `PATH` if it was added solely for Amulet.

**Delete the exported plaintext file** (if you created one in Step 1):

```sh
rm exported-secrets.env
```

---

## Checklist

- [ ] All secrets exported and verified against `amulet list` output
- [ ] Exported values migrated to the new destination
- [ ] Code updated — no remaining `amulet unseal` calls
- [ ] `secrets.vault` deleted (and removed from git if committed)
- [ ] `amulet` binary removed
- [ ] Plaintext export file deleted
