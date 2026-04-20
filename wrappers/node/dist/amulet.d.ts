export interface AmuletOptions {
    /** Path to the amulet binary. Defaults to 'amulet' (resolved via PATH). */
    binaryPath?: string;
}
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
export declare function withSecret<T>(key: string, vaultPath: string, passphrase: Buffer | string, callback: (secret: Buffer) => Promise<T> | T, options?: AmuletOptions): Promise<T>;
//# sourceMappingURL=amulet.d.ts.map