---
title: "Concepts & Fundamentals"
description: "Understanding the terminal, standard I/O, memory vs. disk, and the core philosophy of Amulet."
order: 1
---

Amulet is built with a unique "philosophy" compared to traditional secret managers. This page provides a gentle introduction to computer fundamentals and how Amulet works, making it accessible even for those new to the terminal.

---

## 1. The Terminal: A Window for Dialogue

The terminal (also known as the command line or console) is a gateway to giving direct instructions to your computer using text.

*   **macOS / Linux**: `Terminal.app`, `zsh`, or `bash`
*   **Windows**: `PowerShell`, `Command Prompt`, or `Windows Terminal`

Amulet is a **CLI (Command Line Interface) tool** that runs in this terminal. Instead of clicking buttons with a mouse, you interact with it by typing commands.

---

## 2. Disk vs. Memory: The Crucial Difference

To understand security, you must understand **where information is stored**.

| Location | Characteristics | Security Property |
| :--- | :--- | :--- |
| **Disk (SSD/HDD)** | Data remains after power-off (Files) | **Leaves a "trace"**. Risk of theft or unintended reading by AI/malware. |
| **Memory (RAM)** | Temporary workspace; wiped on power-off | **Exists only for a "moment"**. Secrets are kept while the app runs and disappear afterward. |

### The Amulet Solution
Many tools store secrets in a `.env` file on the **disk**. This is like leaving your keys on a desk without a lock.

Amulet stores secrets as an **encrypted "Vault"** on the disk. When you need them, it injects them directly into **memory**. This ensures that plaintext secrets (readable by anyone) never touch the disk for even a second.

---

## 3. "Standard I/O" and "Pipes"

The key to mastering Amulet lies in a traditional Unix/Linux mechanism called **"Standard I/O"**.

*   **Standard Input (stdin)**: The entrance where information is "poured into" a program.
*   **Standard Output (stdout)**: The exit where a program "spits out" its results.

### The Pipe `|`: A Digital Bucket Brigade
In the terminal, you can use the `|` (pipe) symbol to connect the "exit" of one program directly to the "entrance" of another.

```bash
echo -n "my-secret-key" | amulet seal MY_KEY
```

In this command:
1. `echo` outputs the secret string.
2. Without writing it to a file,
3. It passes through **memory (the pipe)** directly into `amulet`.

This is why Amulet is said to "leave no trace."

---

## 4. Note for Windows Users

You can perform the same pipe operations in Windows **PowerShell**. However, PowerShell handles text encoding differently.

*   **Unix-like**: `echo -n "value" | ...`
*   **PowerShell**: `echo "value" | ...` (PowerShell may add a newline by default, but Amulet is designed to handle these cases gracefully).

Amulet provides the same secure, disk-free workflow in Windows environments.

---

## 5. Amulet's Role in the AI Era

Today, AI assistants like GitHub Copilot and ChatGPT help us write code. While convenient, this introduces a major risk.

**"AI models may scan your project's `.env` files or plaintext secrets and include them in their training data or prompts."**

### What Amulet Protects
By using Amulet, your project directory contains only "unreadable, encrypted files."

*   **To the AI**: Your secrets are invisible, allowing it to support your development safely.
*   **To You**: You are physically prevented from accidentally pushing a password to GitHub.

---

## Next Steps

Now that you understand the core concepts, let's [Get Started](getting-started) by installing Amulet and sealing your first secret.
