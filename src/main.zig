const std = @import("std");
const crypto_mod = @import("crypto.zig");
const probe_id = @import("probe_id.zig");

// ── Vault file on-disk format ─────────────────────────────────────────────────
//
// Sequence of entries (no fixed header; empty file = empty vault):
//   [2 byte big-endian]  key_name_length
//   [key_name_length]    key_name bytes
//   [4 byte big-endian]  blob_length
//   [blob_length]        crypto blob (produced by crypto.sealEntry)
//

const default_vault_path = "amulet.vault";
const max_secret_len: usize = 64 * 1024;
const max_passphrase_len: usize = 1024;
const max_key_name_len: usize = 255;

const Entry = struct {
    key: []u8,
    blob: []u8,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.blob);
    }
};

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    run(allocator) catch |err| {
        switch (err) {
            error.Usage => {
                printUsage();
                std.process.exit(2);
            },
            else => std.process.exit(1),
        }
    };
}

const CliError = error{Usage};

fn run(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) return error.Usage;

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "init")) {
        return cmdInit(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "seal")) {
        return cmdSeal(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "unseal")) {
        cmdUnseal(allocator, args[2..]);
    } else {
        return error.Usage;
    }
}

// ── init ──────────────────────────────────────────────────────────────────────

fn cmdInit(allocator: std.mem.Allocator, args: [][]u8) !void {
    _ = allocator;
    const vault_path = parseFileFlag(args) orelse default_vault_path;

    const file = std.fs.cwd().createFile(vault_path, .{
        .exclusive = true,
        .mode = 0o600,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.io.getStdErr().writer().print(
                "init failed: vault already exists: {s}\n",
                .{vault_path},
            ) catch {};
            std.process.exit(1);
        },
        else => return err,
    };
    file.close();
}

// ── seal ──────────────────────────────────────────────────────────────────────

fn cmdSeal(allocator: std.mem.Allocator, args: [][]u8) !void {
    var portable = false;
    var rest = args;

    if (rest.len > 0 and std.mem.eql(u8, rest[0], "--portable")) {
        portable = true;
        rest = rest[1..];
        std.io.getStdErr().writer().print(
            "WARNING: portable mode reduces security\n",
            .{},
        ) catch {};
    }

    if (rest.len < 1) return error.Usage;
    const key_name = rest[0];
    if (key_name.len == 0 or key_name.len > max_key_name_len) return error.Usage;
    const vault_path = parseFileFlag(rest[1..]) orelse default_vault_path;

    // Passphrase from /dev/tty (echo suppressed)
    const passphrase = readPassphraseTty(allocator) catch {
        std.io.getStdErr().writer().print(
            "seal failed: cannot open terminal for passphrase\n",
            .{},
        ) catch {};
        std.process.exit(1);
    };
    defer {
        std.crypto.utils.secureZero(u8, passphrase);
        allocator.free(passphrase);
    }

    // Secret from stdin
    const secret = readStdinSecret(allocator) catch {
        std.io.getStdErr().writer().print(
            "seal failed: cannot read secret from stdin\n",
            .{},
        ) catch {};
        std.process.exit(1);
    };
    defer {
        std.crypto.utils.secureZero(u8, secret);
        allocator.free(secret);
    }

    // Machine ID (locked mode only)
    const machine_id: ?[]u8 = if (!portable) blk: {
        const id = probe_id.getMachineId(allocator) catch {
            std.io.getStdErr().writer().print(
                "seal failed: cannot retrieve machine ID\n",
                .{},
            ) catch {};
            std.process.exit(1);
        };
        break :blk id;
    } else null;
    defer if (machine_id) |id| {
        std.crypto.utils.secureZero(u8, id);
        allocator.free(id);
    };

    // Produce crypto blob
    var blob_buf = std.ArrayList(u8).init(allocator);
    defer blob_buf.deinit();
    try crypto_mod.sealEntry(
        allocator,
        blob_buf.writer(),
        secret,
        passphrase,
        machine_id,
        portable,
    );

    // Load existing vault (empty ArrayList if file doesn't exist yet)
    var entries = loadVault(allocator, vault_path) catch |err| switch (err) {
        error.FileNotFound => std.ArrayList(Entry).init(allocator),
        else => return err,
    };
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }

    // Replace or append entry
    var replaced = false;
    for (entries.items) |*e| {
        if (std.mem.eql(u8, e.key, key_name)) {
            allocator.free(e.blob);
            e.blob = try allocator.dupe(u8, blob_buf.items);
            replaced = true;
            break;
        }
    }
    if (!replaced) {
        try entries.append(.{
            .key = try allocator.dupe(u8, key_name),
            .blob = try allocator.dupe(u8, blob_buf.items),
        });
    }

    try writeVaultAtomic(allocator, vault_path, entries.items);
}

// ── unseal ────────────────────────────────────────────────────────────────────

// Wrapper that converts any error to a silent exit(1).
fn cmdUnseal(allocator: std.mem.Allocator, args: [][]u8) void {
    unsealInner(allocator, args) catch std.process.exit(1);
}

fn unsealInner(allocator: std.mem.Allocator, args: [][]u8) !void {
    if (args.len < 1) std.process.exit(1);
    const key_name = args[0];
    const vault_path = parseFileFlag(args[1..]) orelse default_vault_path;

    // Passphrase from stdin first line
    const passphrase = readStdinLine(allocator) catch std.process.exit(1);
    defer {
        std.crypto.utils.secureZero(u8, passphrase);
        allocator.free(passphrase);
    }

    // Machine ID for locked-mode vaults (failure is OK; unsealEntry will reject if needed)
    const machine_id: ?[]u8 = probe_id.getMachineId(allocator) catch null;
    defer if (machine_id) |id| {
        std.crypto.utils.secureZero(u8, id);
        allocator.free(id);
    };

    // Find the blob for this key
    var entries = loadVault(allocator, vault_path) catch std.process.exit(1);
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }

    const blob: []u8 = for (entries.items) |e| {
        if (std.mem.eql(u8, e.key, key_name)) break e.blob;
    } else std.process.exit(1);

    // Decrypt (mode auto-detected from vault header flags)
    var stream = std.io.fixedBufferStream(blob);
    const plaintext = crypto_mod.unsealEntry(
        allocator,
        stream.reader(),
        passphrase,
        machine_id,
    ) catch std.process.exit(1);
    defer {
        std.crypto.utils.secureZero(u8, plaintext);
        allocator.free(plaintext);
    }

    // Secret to stdout only, no trailing newline
    std.io.getStdOut().writeAll(plaintext) catch std.process.exit(1);
}

// ── Vault I/O ─────────────────────────────────────────────────────────────────

fn loadVault(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(Entry) {
    const file = try openVaultReadOnly(path);
    defer file.close();

    var entries = std.ArrayList(Entry).init(allocator);
    errdefer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }

    const reader = file.reader();
    while (true) {
        const key_len = reader.readInt(u16, .big) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (key_len == 0 or key_len > max_key_name_len) return error.InvalidVault;

        const key = try allocator.alloc(u8, key_len);
        errdefer allocator.free(key);
        try reader.readNoEof(key);

        const blob_len = try reader.readInt(u32, .big);
        // Upper bound: max_secret_len plaintext + crypto overhead (salt+nonce+len+tag = 50 bytes)
        if (blob_len > max_secret_len + 128) return error.InvalidVault;
        const blob = try allocator.alloc(u8, blob_len);
        errdefer allocator.free(blob);
        try reader.readNoEof(blob);

        try entries.append(.{ .key = key, .blob = blob });
    }
    return entries;
}

fn writeVaultAtomic(
    allocator: std.mem.Allocator,
    vault_path: []const u8,
    entries: []const Entry,
) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{vault_path});
    defer allocator.free(tmp_path);

    {
        const tmp_file = try std.fs.cwd().createFile(tmp_path, .{ .mode = 0o600 });
        defer tmp_file.close();
        const writer = tmp_file.writer();
        for (entries) |e| {
            try writer.writeInt(u16, @intCast(e.key.len), .big);
            try writer.writeAll(e.key);
            try writer.writeInt(u32, @intCast(e.blob.len), .big);
            try writer.writeAll(e.blob);
        }
    }

    try std.fs.cwd().rename(tmp_path, vault_path);
}

/// Open vault read-only with O_NOFOLLOW to prevent symlink attacks.
fn openVaultReadOnly(path: []const u8) !std.fs.File {
    const flags: std.posix.O = .{
        .NOFOLLOW = true,
        .ACCMODE = .RDONLY,
    };
    const fd = try std.posix.open(path, flags, 0);
    return std.fs.File{ .handle = fd };
}

// ── Input helpers ─────────────────────────────────────────────────────────────

/// Read passphrase from /dev/tty with echo disabled. Prompts "Passphrase: ".
fn readPassphraseTty(allocator: std.mem.Allocator) ![]u8 {
    const tty = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
    defer tty.close();

    var tio = try std.posix.tcgetattr(tty.handle);
    const saved = tio;
    tio.lflag.ECHO = false;
    tio.lflag.ECHONL = false;
    try std.posix.tcsetattr(tty.handle, .FLUSH, tio);
    defer std.posix.tcsetattr(tty.handle, .FLUSH, saved) catch {};

    try tty.writeAll("Passphrase: ");

    var buf = std.ArrayList(u8).init(allocator);
    errdefer {
        std.crypto.utils.secureZero(u8, buf.items);
        buf.deinit();
    }

    var byte: [1]u8 = undefined;
    while (buf.items.len < max_passphrase_len) {
        const n = try tty.read(&byte);
        if (n == 0 or byte[0] == '\n' or byte[0] == '\r') break;
        try buf.append(byte[0]);
    }
    try tty.writeAll("\n");

    return buf.toOwnedSlice();
}

/// Read first line from stdin (strips trailing newline). Used for unseal passphrase.
fn readStdinLine(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer {
        std.crypto.utils.secureZero(u8, buf.items);
        buf.deinit();
    }
    std.io.getStdIn().reader().streamUntilDelimiter(
        buf.writer(),
        '\n',
        max_passphrase_len,
    ) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };
    return buf.toOwnedSlice();
}

/// Read all of stdin as the secret value (for seal).
fn readStdinSecret(allocator: std.mem.Allocator) ![]u8 {
    const data = try std.io.getStdIn().readToEndAlloc(allocator, max_secret_len);
    errdefer {
        std.crypto.utils.secureZero(u8, data);
        allocator.free(data);
    }
    return data;
}

// ── Misc ──────────────────────────────────────────────────────────────────────

/// Scan `args` for `--file <path>` and return the path, or null.
fn parseFileFlag(args: [][]u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--file")) return args[i + 1];
    }
    return null;
}

fn printUsage() void {
    std.io.getStdErr().writer().writeAll(
        \\Usage:
        \\  amulet init                       [--file <vault>]
        \\  amulet seal   [--portable] <key>  [--file <vault>]
        \\  amulet unseal <key>               [--file <vault>]
        \\
        \\  seal:   passphrase prompted from /dev/tty, secret read from stdin
        \\  unseal: passphrase read from stdin (first line), secret written to stdout
        \\
    ) catch {};
}
