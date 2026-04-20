/**
 * Integration tests for the amulet Node.js wrapper.
 * Uses Node.js built-in test runner (no external deps required).
 *
 * Prerequisites: `zig build` must have been run so the binary exists.
 */

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execSync, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

// ── Resolve paths ─────────────────────────────────────────────────────────────

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const repoRoot = resolve(__dirname, '../../..');
const BINARY = join(repoRoot, 'zig-out/bin/amulet');

// Import the wrapper (compiled JS or directly via ts-node if available)
// We import the TypeScript source via ts-node/esm loader, or fall back to
// a simple inline re-implementation for pure-JS testing.
// Since `node --test` doesn't load ts-node by default, we compile first.
// The test script in package.json handles compilation; here we import dist/.
const { withSecret } = await import('../dist/amulet.js').catch(() => {
  throw new Error(
    'Run `npm run build` in wrappers/node before running tests.',
  );
});

// ── Test fixtures ─────────────────────────────────────────────────────────────

let tmpDir;
let vaultPath;
const PASSPHRASE = 'test-passphrase-do-not-use-in-prod';
const SECRET_VALUE = 'sk-test-1234567890abcdef';
const KEY_NAME = 'TEST_API_KEY';

before(() => {
  tmpDir = mkdtempSync(join(tmpdir(), 'amulet-test-'));
  vaultPath = join(tmpDir, 'test.vault');

  // Seal a test secret using the CLI (portable mode, passphrase via stdin trick)
  // amulet seal reads passphrase from /dev/tty; use `expect` wrapper to feed it.
  const result = spawnSync(
    'expect',
    [
      '-c',
      `spawn sh -c {printf "${SECRET_VALUE}" | ${BINARY} seal --portable ${KEY_NAME} --file ${vaultPath}}
       expect "Passphrase: "
       send "${PASSPHRASE}\\r"
       expect eof`,
    ],
    { encoding: 'utf8' },
  );
  if (result.status !== 0) {
    throw new Error(`Test fixture setup failed:\n${result.stdout}\n${result.stderr}`);
  }
});

after(() => {
  if (tmpDir) rmSync(tmpDir, { recursive: true, force: true });
});

// ── Tests ─────────────────────────────────────────────────────────────────────

test('withSecret: correct passphrase returns expected secret', async () => {
  let captured;
  await withSecret(KEY_NAME, vaultPath, PASSPHRASE, (secret) => {
    assert.ok(Buffer.isBuffer(secret), 'secret must be a Buffer');
    captured = Buffer.from(secret); // copy so we can check value after callback
  }, { binaryPath: BINARY });

  assert.ok(captured.toString('utf8') === SECRET_VALUE, 'decrypted value must match');
  captured.fill(0);
});

test('withSecret: secret Buffer is zeroed after callback', async () => {
  let secretRef;
  await withSecret(KEY_NAME, vaultPath, PASSPHRASE, (secret) => {
    secretRef = secret; // intentionally hold reference
  }, { binaryPath: BINARY });

  // After withSecret resolves, the Buffer should be all zeros
  assert.ok(
    secretRef.every((b) => b === 0),
    'Buffer must be zeroed after callback',
  );
});

test('withSecret: secret Buffer is zeroed even when callback throws', async () => {
  let secretRef;
  const boom = new Error('intentional');

  await assert.rejects(
    () =>
      withSecret(KEY_NAME, vaultPath, PASSPHRASE, (secret) => {
        secretRef = secret;
        throw boom;
      }, { binaryPath: BINARY }),
    boom,
  );

  assert.ok(
    secretRef.every((b) => b === 0),
    'Buffer must be zeroed even after callback throws',
  );
});

test('withSecret: wrong passphrase rejects with an error', async () => {
  await assert.rejects(
    () =>
      withSecret(KEY_NAME, vaultPath, 'wrong-passphrase', () => {}, {
        binaryPath: BINARY,
      }),
    /unseal failed/,
  );
});

test('withSecret: missing key rejects with an error', async () => {
  await assert.rejects(
    () =>
      withSecret('NONEXISTENT_KEY', vaultPath, PASSPHRASE, () => {}, {
        binaryPath: BINARY,
      }),
    /unseal failed/,
  );
});

test('withSecret: passphrase as Buffer is accepted', async () => {
  const passphraseBuf = Buffer.from(PASSPHRASE, 'utf8');
  let received = false;
  await withSecret(KEY_NAME, vaultPath, passphraseBuf, (secret) => {
    assert.ok(Buffer.isBuffer(secret));
    received = true;
  }, { binaryPath: BINARY });
  assert.ok(received);
});

test('withSecret: callback return value is propagated', async () => {
  const result = await withSecret(
    KEY_NAME,
    vaultPath,
    PASSPHRASE,
    (secret) => secret.length,
    { binaryPath: BINARY },
  );
  assert.ok(typeof result === 'number' && result > 0);
});
