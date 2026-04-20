const std = @import("std");
const crypto = std.crypto;
const argon2 = crypto.pwhash.argon2;
const ChaCha20Poly1305 = crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const vault_version: u8 = 0x01;
pub const flag_portable: u8 = 0x01;

pub const salt_len: usize = 16;
pub const nonce_len: usize = ChaCha20Poly1305.nonce_length; // 12
pub const key_len: usize = ChaCha20Poly1305.key_length; // 32
pub const tag_len: usize = ChaCha20Poly1305.tag_length; // 16

/// Vault header size: version(1) + flags(1) + salt(16) + nonce(12) = 30 bytes
pub const header_size: usize = 1 + 1 + salt_len + nonce_len;

/// Argon2id parameters: m=64MiB, t=3, p=1
pub const kdf_params = argon2.Params{ .t = 3, .m = 65536, .p = 1 };

/// Maximum plaintext size accepted by unsealEntry (64 KiB).
/// Guards against malformed ciphertext-length fields.
pub const max_plaintext_len: u32 = 64 * 1024;

pub const SealError = error{OutOfMemory};
pub const UnsealError = error{
    UnsupportedVersion,
    UnknownFlags,
    VaultTooLarge,
    AuthenticationFailed,
    OutOfMemory,
    EndOfStream,
};

// ── Public API ────────────────────────────────────────────────────────────────

/// Encrypt `plaintext` and write a vault blob to `writer`.
///
/// Locked mode  (portable=false): pass a non-null `machine_id`.
/// Portable mode (portable=true): pass null for `machine_id`.
///
/// Sensitive memory (key, kdf_input) is zeroed before this function returns.
pub fn sealEntry(
    allocator: std.mem.Allocator,
    writer: anytype,
    plaintext: []const u8,
    passphrase: []const u8,
    machine_id: ?[]const u8,
    portable: bool,
) !void {
    var salt: [salt_len]u8 = undefined;
    var nonce: [nonce_len]u8 = undefined;
    crypto.random.bytes(&salt);
    crypto.random.bytes(&nonce);

    var key: [key_len]u8 = undefined;
    defer std.crypto.utils.secureZero(u8, &key);
    try deriveKey(allocator, &key, passphrase, if (portable) null else machine_id, &salt);

    const ciphertext = try allocator.alloc(u8, plaintext.len);
    defer allocator.free(ciphertext);
    var tag: [tag_len]u8 = undefined;
    const aad = [_]u8{vault_version};
    ChaCha20Poly1305.encrypt(ciphertext, &tag, plaintext, &aad, nonce, key);

    const flags: u8 = if (portable) flag_portable else 0;
    try writer.writeByte(vault_version);
    try writer.writeByte(flags);
    try writer.writeAll(&salt);
    try writer.writeAll(&nonce);
    try writer.writeInt(u32, @intCast(plaintext.len), .big);
    try writer.writeAll(ciphertext);
    try writer.writeAll(&tag);
}

/// Decrypt a vault blob read from `reader`. Returns an allocated plaintext slice.
/// The caller is responsible for zeroing and freeing the returned slice.
///
/// Mode is auto-detected from the vault header flags byte.
/// `machine_id` is only used when the vault was sealed in Locked mode.
///
/// On any failure (wrong passphrase, wrong machine, corrupt data, bad version)
/// the error is returned without leaking diagnostic details — callers should
/// treat all errors equivalently and exit with a non-zero code.
pub fn unsealEntry(
    allocator: std.mem.Allocator,
    reader: anytype,
    passphrase: []const u8,
    machine_id: ?[]const u8,
) ![]u8 {
    const version = try reader.readByte();
    if (version != vault_version) return error.UnsupportedVersion;

    const flags = try reader.readByte();
    if (flags & ~flag_portable != 0) return error.UnknownFlags;
    const portable = (flags & flag_portable) != 0;

    var salt: [salt_len]u8 = undefined;
    var nonce: [nonce_len]u8 = undefined;
    try reader.readNoEof(&salt);
    try reader.readNoEof(&nonce);

    const ct_len = try reader.readInt(u32, .big);
    if (ct_len > max_plaintext_len) return error.VaultTooLarge;

    const ciphertext = try allocator.alloc(u8, ct_len);
    defer allocator.free(ciphertext);
    try reader.readNoEof(ciphertext);

    var tag: [tag_len]u8 = undefined;
    try reader.readNoEof(&tag);

    var key: [key_len]u8 = undefined;
    defer std.crypto.utils.secureZero(u8, &key);
    try deriveKey(allocator, &key, passphrase, if (portable) null else machine_id, &salt);

    const plaintext = try allocator.alloc(u8, ct_len);
    errdefer {
        std.crypto.utils.secureZero(u8, plaintext);
        allocator.free(plaintext);
    }
    const aad = [_]u8{vault_version};
    ChaCha20Poly1305.decrypt(plaintext, ciphertext, tag, &aad, nonce, key) catch {
        return error.AuthenticationFailed;
    };
    return plaintext;
}

// ── Internal ──────────────────────────────────────────────────────────────────

/// Build Argon2id password input and derive a 32-byte key.
///
/// Locked:   kdf_password = passphrase ‖ 0x00 ‖ machine_id
/// Portable: kdf_password = passphrase
///
/// The heap buffer holding kdf_password is zeroed before being freed.
fn deriveKey(
    allocator: std.mem.Allocator,
    out_key: *[key_len]u8,
    passphrase: []const u8,
    machine_id: ?[]const u8,
    salt: *const [salt_len]u8,
) !void {
    const kdf_input: []u8 = if (machine_id) |mid| blk: {
        const buf = try allocator.alloc(u8, passphrase.len + 1 + mid.len);
        @memcpy(buf[0..passphrase.len], passphrase);
        buf[passphrase.len] = 0x00;
        @memcpy(buf[passphrase.len + 1 ..], mid);
        break :blk buf;
    } else try allocator.dupe(u8, passphrase);
    defer {
        std.crypto.utils.secureZero(u8, kdf_input);
        allocator.free(kdf_input);
    }

    try argon2.kdf(allocator, out_key, kdf_input, salt, kdf_params, .argon2id);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "seal/unseal round-trip: locked mode" {
    const allocator = std.testing.allocator;
    const passphrase = "correct-horse-battery-staple";
    const machine_id = "6508611f95ca593e9965be857ccfbe33";
    const secret = "sk-proj-secret-value-1234";

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try sealEntry(allocator, buf.writer(), secret, passphrase, machine_id, false);

    var stream = std.io.fixedBufferStream(buf.items);
    const result = try unsealEntry(allocator, stream.reader(), passphrase, machine_id);
    defer {
        std.crypto.utils.secureZero(u8, result);
        allocator.free(result);
    }
    try std.testing.expectEqualStrings(secret, result);
}

test "seal/unseal round-trip: portable mode" {
    const allocator = std.testing.allocator;
    const passphrase = "portable-passphrase";
    const secret = "portable-secret";

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try sealEntry(allocator, buf.writer(), secret, passphrase, null, true);

    var stream = std.io.fixedBufferStream(buf.items);
    // machine_id is irrelevant in portable mode
    const result = try unsealEntry(allocator, stream.reader(), passphrase, null);
    defer {
        std.crypto.utils.secureZero(u8, result);
        allocator.free(result);
    }
    try std.testing.expectEqualStrings(secret, result);
}

test "wrong passphrase returns AuthenticationFailed" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try sealEntry(allocator, buf.writer(), "secret", "right-pass", null, true);

    var stream = std.io.fixedBufferStream(buf.items);
    const err = unsealEntry(allocator, stream.reader(), "wrong-pass", null);
    try std.testing.expectError(error.AuthenticationFailed, err);
}

test "wrong machine_id returns AuthenticationFailed" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try sealEntry(allocator, buf.writer(), "secret", "passphrase", "machine-a", false);

    var stream = std.io.fixedBufferStream(buf.items);
    const err = unsealEntry(allocator, stream.reader(), "passphrase", "machine-b");
    try std.testing.expectError(error.AuthenticationFailed, err);
}

test "portable vault ignores machine_id on unseal" {
    const allocator = std.testing.allocator;
    const secret = "cross-machine-secret";

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try sealEntry(allocator, buf.writer(), secret, "pass", null, true);

    // Provide a machine_id — it must be silently ignored because vault is portable
    var stream = std.io.fixedBufferStream(buf.items);
    const result = try unsealEntry(allocator, stream.reader(), "pass", "any-machine-id");
    defer {
        std.crypto.utils.secureZero(u8, result);
        allocator.free(result);
    }
    try std.testing.expectEqualStrings(secret, result);
}

test "unknown flags byte returns UnknownFlags" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    // Write a vault with flags = 0xFF (all bits set, most are unknown)
    try buf.writer().writeByte(vault_version);
    try buf.writer().writeByte(0xFF);
    // Remaining bytes don't matter — error fires before they're read
    try buf.writer().writeByteNTimes(0, 64);

    var stream = std.io.fixedBufferStream(buf.items);
    const err = unsealEntry(allocator, stream.reader(), "pass", null);
    try std.testing.expectError(error.UnknownFlags, err);
}

test "unsupported vault version returns UnsupportedVersion" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try buf.writer().writeByte(0x02); // future version
    try buf.writer().writeByteNTimes(0, 64);

    var stream = std.io.fixedBufferStream(buf.items);
    const err = unsealEntry(allocator, stream.reader(), "pass", null);
    try std.testing.expectError(error.UnsupportedVersion, err);
}

test "vault blob size matches expected layout" {
    const allocator = std.testing.allocator;
    const secret = "x";

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try sealEntry(allocator, buf.writer(), secret, "p", null, true);

    // version(1) + flags(1) + salt(16) + nonce(12) + len(4) + ct(1) + tag(16) = 51
    try std.testing.expectEqual(@as(usize, 51), buf.items.len);
}
