"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.withSecret = withSecret;
const node_child_process_1 = require("node:child_process");
const MAX_OUTPUT_BYTES = 64 * 1024;
/**
 * Unseal a secret and pass it as an opaque Buffer to `callback`.
 *
 * The Buffer is zeroed in a `finally` block after the callback returns,
 * regardless of success or failure. The secret never exists as a string.
 *
 * @param key        - Key name stored in the vault.
 * @param vaultPath  - Path to the vault file.
 * @param passphrase - Passphrase (Buffer preferred; string is accepted but less secure).
 * @param callback   - Receives the secret Buffer. Do not store a reference past this call.
 * @param options    - Optional: override `binaryPath`.
 *
 * @example
 * await withSecret('OPENAI_API_KEY', 'secrets.vault', passphraseBuf, async (secret) => {
 *   await callApi(secret); // use secret here only
 * });
 */
async function withSecret(key, vaultPath, passphrase, callback, options = {}) {
    const secret = await spawnUnseal(options.binaryPath ?? 'amulet', key, vaultPath, passphrase);
    try {
        return await callback(secret);
    }
    finally {
        secret.fill(0);
    }
}
// ── Internal ──────────────────────────────────────────────────────────────────
function spawnUnseal(binary, key, vaultPath, passphrase) {
    return new Promise((resolve, reject) => {
        const child = (0, node_child_process_1.spawn)(binary, ['unseal', key, '--file', vaultPath], {
            stdio: ['pipe', 'pipe', 'ignore'], // stderr discarded
        });
        // Send passphrase as first stdin line, then close stdin immediately.
        // We work in a temporary Buffer so we can zero it before resolve/reject.
        const passphraseBytes = typeof passphrase === 'string'
            ? Buffer.from(passphrase, 'utf8')
            : Buffer.from(passphrase); // copy — we zero our own copy
        const stdinFrame = Buffer.concat([passphraseBytes, Buffer.from('\n')]);
        passphraseBytes.fill(0);
        child.stdin.write(stdinFrame, () => {
            stdinFrame.fill(0);
            child.stdin.end();
        });
        const chunks = [];
        let totalBytes = 0;
        let overLimit = false;
        child.stdout.on('data', (chunk) => {
            if (overLimit)
                return;
            totalBytes += chunk.length;
            if (totalBytes > MAX_OUTPUT_BYTES) {
                overLimit = true;
                child.kill();
                zeroAndClear(chunks);
                reject(new Error('amulet: output exceeded size limit'));
                return;
            }
            chunks.push(Buffer.from(chunk)); // copy chunk before Node recycles the buffer
        });
        child.on('close', (code) => {
            if (overLimit)
                return; // already rejected
            if (code !== 0) {
                zeroAndClear(chunks);
                reject(new Error('amulet: unseal failed'));
                return;
            }
            const result = Buffer.concat(chunks);
            zeroAndClear(chunks); // zero individual chunks after concat copies them
            resolve(result);
        });
        child.on('error', (err) => {
            zeroAndClear(chunks);
            reject(err);
        });
    });
}
function zeroAndClear(chunks) {
    for (const c of chunks)
        c.fill(0);
    chunks.length = 0;
}
//# sourceMappingURL=amulet.js.map