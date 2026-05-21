---
title: "Installation & Setup"
description: "How to install Amulet CLI and save your first secret."
order: 2
---

This page guides you through installing Amulet and performing your first seal/unseal operations.

:::note
If you want to learn about the "Concepts" behind Amulet, such as how it uses memory vs. disk or the Unix philosophy, please check the **[Concepts & Philosophy](concepts)** page first.
:::

---

## 1. Installation

Choose the command for your operating system.

### macOS
The easiest way is via [Homebrew](https://brew.sh/).

```sh
brew tap tsukasa-art/amulet
brew install amulet
```

### Windows
You can install via [Scoop](https://scoop.sh/).

```powershell
# Add the bucket and install
scoop bucket add amulet https://github.com/tsukasa-art/scoop-amulet.git
scoop install amulet
```

### Linux (or direct curl install)
Download the binary directly from GitHub Releases and place it in `~/.local/bin`.

```sh
curl -fL -o ~/.local/bin/amulet \
  https://github.com/tsukasa-art/amulet/releases/latest/download/amulet-linux-x86_64
chmod +x ~/.local/bin/amulet
```

`~/.local/bin` is on `$PATH` by default on most modern Linux distributions. If `amulet` is not found after install, add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile.

---

## 2. Seal Your First Secret

Once installed, let's try saving a secret. We'll use the key name `MY_SECRET`.

```bash
# Encrypt and save the value "my-password-123"
echo -n "my-password-123" | amulet seal MY_SECRET --file secrets.vault
```

You will be prompted for a **passphrase**. This passphrase is required to retrieve your data later, so don't forget it!

::: tip
A file named `secrets.vault` will be created. It's encrypted and safe to commit to GitHub.
:::

---

## 3. Retrieve Your Secret (Unseal)

Now, let's get the secret back.

```bash
amulet unseal MY_SECRET --file secrets.vault
```

Enter your passphrase, and `my-password-123` will be displayed. You've mastered the basics!

---

## 4. Pro Tip: Auto-filling Passphrase

If typing the passphrase every time is tedious, you can set the `VAULT_PASSPHRASE` environment variable.

```bash
export VAULT_PASSPHRASE="your-passphrase"
amulet unseal MY_SECRET --file secrets.vault
```

::: caution
Avoid setting the passphrase in environment variables on shared machines or environments where others might see your screen.
:::

---

## Next Steps

*   **[Usage Reference](usage)**: Explore detailed command options.
*   **[Deployment](deployment)**: Learn how to run Amulet on servers or Docker.
*   **[Security Design](security)**: Deep dive into how Amulet protects your data.
