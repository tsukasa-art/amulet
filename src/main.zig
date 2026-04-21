const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const crypto_mod = @import("crypto.zig");
const probe_id = @import("probe_id.zig");

// In Debug builds, fall back to the default panic handler (shows stack trace).
// In all other builds, exit silently — consistent with Amulet's no-diagnostic policy.
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (builtin.mode == .Debug) {
        std.builtin.default_panic(msg, error_return_trace, ret_addr);
    }
    std.process.exit(1);
}

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

const Command = enum {
    help,
    init,
    seal,
    unseal,
    version,
    list,
    delete,
    verify,
    re_seal,
    import,
    rename,
    probe,
};

fn parseCommand(str: []const u8) ?Command {
    if (std.mem.eql(u8, str, "help") or
        std.mem.eql(u8, str, "-h") or
        std.mem.eql(u8, str, "--help")) return .help;
    if (std.mem.eql(u8, str, "init")) return .init;
    if (std.mem.eql(u8, str, "seal")) return .seal;
    if (std.mem.eql(u8, str, "unseal")) return .unseal;
    if (std.mem.eql(u8, str, "version")) return .version;
    if (std.mem.eql(u8, str, "list")) return .list;
    if (std.mem.eql(u8, str, "delete")) return .delete;
    if (std.mem.eql(u8, str, "verify")) return .verify;
    if (std.mem.eql(u8, str, "re-seal")) return .re_seal;
    if (std.mem.eql(u8, str, "import")) return .import;
    if (std.mem.eql(u8, str, "rename")) return .rename;
    if (std.mem.eql(u8, str, "probe")) return .probe;
    return null;
}

fn run(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) return error.Usage;

    const cmd = parseCommand(args[1]) orelse return error.Usage;

    switch (cmd) {
        .help => {
            if (args.len != 2) return error.Usage;
            return cmdHelp();
        },
        .init => return cmdInit(allocator, args[2..]),
        .seal => return cmdSeal(allocator, args[2..]),
        .unseal => cmdUnseal(allocator, args[2..]),
        .version => {
            if (args.len != 2) return error.Usage;
            return cmdVersion();
        },
        .list => {
            if (!argsAreOnlyFileFlagPairs(args[2..])) return error.Usage;
            return cmdList(allocator, args[2..]);
        },
        .delete => {
            if (args.len < 3) return error.Usage;
            const rest = args[2..];
            if (rest.len < 1 or std.mem.eql(u8, rest[0], "--file")) return error.Usage;
            if (!argsAreOnlyFileFlagPairs(rest[1..])) return error.Usage;
            return cmdDelete(allocator, rest);
        },
        .verify => cmdVerify(allocator, args[2..]),
        .re_seal => return cmdReSeal(allocator, args[2..]),
        .import => return cmdImport(allocator, args[2..]),
        .rename => {
            if (args.len < 4) return error.Usage;
            const rest = args[2..];
            if (std.mem.eql(u8, rest[0], "--file") or std.mem.eql(u8, rest[1], "--file")) return error.Usage;
            if (!argsAreOnlyFileFlagPairs(rest[2..])) return error.Usage;
            return cmdRename(allocator, rest);
        },
        .probe => {
            if (args.len != 2) return error.Usage;
            return cmdProbe(allocator);
        },
    }
}

fn cmdVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{build_options.version});
}

fn cmdHelp() !void {
    try std.io.getStdOut().writeAll(usageText());
}

fn cmdList(allocator: std.mem.Allocator, args: [][]u8) !void {
    const vault_path = parseFileFlag(args) orelse default_vault_path;
    var entries = loadVault(allocator, vault_path) catch std.process.exit(1);
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }
    const stdout = std.io.getStdOut().writer();
    for (entries.items) |e| {
        try stdout.print("{s}\n", .{e.key});
    }
}

fn cmdDelete(allocator: std.mem.Allocator, rest: [][]u8) !void {
    const key_name = rest[0];
    if (key_name.len == 0 or key_name.len > max_key_name_len) return error.Usage;
    const vault_path = parseFileFlag(rest[1..]) orelse default_vault_path;

    var entries = loadVault(allocator, vault_path) catch std.process.exit(1);
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }

    var found = false;
    var i: usize = 0;
    while (i < entries.items.len) {
        if (std.mem.eql(u8, entries.items[i].key, key_name)) {
            entries.items[i].deinit(allocator);
            _ = entries.swapRemove(i);
            found = true;
            break;
        } else {
            i += 1;
        }
    }
    if (!found) std.process.exit(1);

    writeVaultAtomic(allocator, vault_path, entries.items) catch std.process.exit(1);
}

fn renameEntryInVault(
    allocator: std.mem.Allocator,
    vault_path: []const u8,
    old_key: []const u8,
    new_key: []const u8,
) !void {
    var entries = try loadVault(allocator, vault_path);
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }

    var old_idx: ?usize = null;
    for (entries.items, 0..) |e, i| {
        if (std.mem.eql(u8, e.key, old_key)) old_idx = i;
        if (std.mem.eql(u8, e.key, new_key)) return error.NewKeyAlreadyExists;
    }
    const idx = old_idx orelse return error.OldKeyNotFound;

    const new_key_copy = try allocator.dupe(u8, new_key);
    allocator.free(entries.items[idx].key);
    entries.items[idx].key = new_key_copy;

    try writeVaultAtomic(allocator, vault_path, entries.items);
}

fn cmdRename(allocator: std.mem.Allocator, rest: [][]u8) !void {
    const old_key = rest[0];
    const new_key = rest[1];
    if (old_key.len == 0 or old_key.len > max_key_name_len) return error.Usage;
    if (new_key.len == 0 or new_key.len > max_key_name_len) return error.Usage;
    const vault_path = parseFileFlag(rest[2..]) orelse default_vault_path;

    renameEntryInVault(allocator, vault_path, old_key, new_key) catch std.process.exit(1);
}

fn cmdProbe(allocator: std.mem.Allocator) !void {
    const id = probe_id.getMachineId(allocator) catch |err| {
        std.process.exit(switch (err) {
            error.NotFound => 2,
            else => 1,
        });
    };
    defer allocator.free(id);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{id});
}

// ── init ──────────────────────────────────────────────────────────────────────

fn cmdInit(allocator: std.mem.Allocator, args: [][]u8) !void {
    _ = allocator;
    const vault_path = parseFileFlag(args) orelse default_vault_path;

    const file = std.fs.cwd().createFile(vault_path, if (comptime builtin.os.tag == .windows)
        .{ .exclusive = true }
    else
        .{ .exclusive = true, .mode = 0o600 }
    ) catch |err| switch (err) {
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

// ── import ────────────────────────────────────────────────────────────────────

const KV = struct { key: []const u8, value: []const u8 };

/// Parse KEY=VALUE lines from `content`. Returns slices into `content` (no copies).
/// Blank lines and `#` comments are skipped. Values with embedded `=` are supported.
fn parseEnvPairs(allocator: std.mem.Allocator, content: []const u8) !std.ArrayList(KV) {
    var pairs = std.ArrayList(KV).init(allocator);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], &std.ascii.whitespace);
        const value = line[eq + 1 ..];
        if (key.len == 0 or key.len > max_key_name_len) continue;
        try pairs.append(.{ .key = key, .value = value });
    }
    return pairs;
}

/// Seal each KV pair into the vault at `vault_path` (upsert). Creates the vault if missing.
fn importPairs(
    allocator: std.mem.Allocator,
    pairs: []const KV,
    passphrase: []const u8,
    machine_id: ?[]const u8,
    portable: bool,
    vault_path: []const u8,
) !void {
    var entries = loadVault(allocator, vault_path) catch |err| switch (err) {
        error.FileNotFound => std.ArrayList(Entry).init(allocator),
        else => return err,
    };
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }

    for (pairs) |kv| {
        var blob_buf = std.ArrayList(u8).init(allocator);
        defer blob_buf.deinit();
        try crypto_mod.sealEntry(allocator, blob_buf.writer(), kv.value, passphrase, machine_id, portable);

        var replaced = false;
        for (entries.items) |*e| {
            if (std.mem.eql(u8, e.key, kv.key)) {
                allocator.free(e.blob);
                e.blob = try allocator.dupe(u8, blob_buf.items);
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            try entries.append(.{
                .key = try allocator.dupe(u8, kv.key),
                .blob = try allocator.dupe(u8, blob_buf.items),
            });
        }
    }

    try writeVaultAtomic(allocator, vault_path, entries.items);
}

fn cmdImport(allocator: std.mem.Allocator, args: [][]u8) !void {
    // Parse flags: --env-file <path> [--portable] [--manifest <path>] [--wipe] [--file <vault>]
    var env_file_path: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var portable = false;
    var wipe = false;
    var vault_path: []const u8 = default_vault_path;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--env-file")) {
            if (i + 1 >= args.len) return error.Usage;
            i += 1;
            env_file_path = args[i];
        } else if (std.mem.eql(u8, a, "--manifest")) {
            if (i + 1 >= args.len) return error.Usage;
            i += 1;
            manifest_path = args[i];
        } else if (std.mem.eql(u8, a, "--file")) {
            if (i + 1 >= args.len) return error.Usage;
            i += 1;
            vault_path = args[i];
        } else if (std.mem.eql(u8, a, "--portable")) {
            portable = true;
        } else if (std.mem.eql(u8, a, "--wipe")) {
            wipe = true;
        } else {
            return error.Usage;
        }
    }
    if (env_file_path == null) return error.Usage;
    const env_path = env_file_path.?;

    if (portable) {
        std.io.getStdErr().writer().print(
            "WARNING: portable mode reduces security\n", .{},
        ) catch {};
    }

    // Passphrase once for all entries
    const passphrase = readPassphraseTty(allocator) catch {
        std.io.getStdErr().writer().print(
            "import failed: cannot open terminal for passphrase\n", .{},
        ) catch {};
        std.process.exit(1);
    };
    defer {
        std.crypto.utils.secureZero(u8, passphrase);
        allocator.free(passphrase);
    }

    // Machine ID (locked mode only)
    const machine_id: ?[]u8 = if (!portable) probe_id.getMachineId(allocator) catch {
        std.io.getStdErr().writer().print(
            "import failed: cannot retrieve machine ID\n", .{},
        ) catch {};
        std.process.exit(1);
    } else null;
    defer if (machine_id) |id| {
        std.crypto.utils.secureZero(u8, id);
        allocator.free(id);
    };

    // Read and parse .env file
    const env_content = std.fs.cwd().readFileAlloc(allocator, env_path, max_secret_len * 256) catch {
        std.io.getStdErr().writer().print(
            "import failed: cannot read {s}\n", .{env_path},
        ) catch {};
        std.process.exit(1);
    };
    defer {
        std.crypto.utils.secureZero(u8, env_content);
        allocator.free(env_content);
    }

    var pairs = parseEnvPairs(allocator, env_content) catch std.process.exit(1);
    defer pairs.deinit();

    if (pairs.items.len == 0) {
        std.io.getStdErr().writer().print(
            "import: no KEY=VALUE entries found in {s}\n", .{env_path},
        ) catch {};
        std.process.exit(1);
    }

    importPairs(allocator, pairs.items, passphrase, machine_id, portable, vault_path) catch std.process.exit(1);

    // Write manifest (key names only) if requested
    if (manifest_path) |mpath| {
        const mfile = std.fs.cwd().createFile(mpath, .{ .truncate = true }) catch {
            std.io.getStdErr().writer().print(
                "import: could not write manifest {s}\n", .{mpath},
            ) catch {};
            std.process.exit(1);
        };
        defer mfile.close();
        const mw = mfile.writer();
        for (pairs.items) |kv| {
            mw.print("{s}\n", .{kv.key}) catch {};
        }
    }

    // Wipe .env values (best-effort, after vault write succeeds)
    if (wipe) {
        wipeEnvValues(env_path, env_content) catch {
            std.io.getStdErr().writer().print(
                "import: vault written but wipe of {s} failed — plaintext may remain\n",
                .{env_path},
            ) catch {};
            std.process.exit(1);
        };
    }
}

/// Overwrite the value portion of each KEY=VALUE line with spaces, leave keys intact.
fn wipeEnvValues(path: []const u8, original: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer file.close();
    try file.seekTo(0);

    var offset: usize = 0;
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |raw_line| {
        const line_len = raw_line.len;
        const trimmed = std.mem.trimRight(u8, raw_line, "\r");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=');
        if (eq) |e| {
            // Write key and '=' as-is, overwrite value with spaces
            try file.seekTo(offset + e + 1);
            const value_len = trimmed.len - (e + 1);
            var j: usize = 0;
            while (j < value_len) : (j += 1) {
                try file.writeAll(" ");
            }
        }
        offset += line_len + 1; // +1 for '\n'
    }
}

// ── re-seal ───────────────────────────────────────────────────────────────────

fn cmdReSeal(allocator: std.mem.Allocator, args: [][]u8) !void {
    if (args.len < 1) return error.Usage;
    const key_name = args[0];
    if (key_name.len == 0 or key_name.len > max_key_name_len) return error.Usage;
    const vault_path = parseFileFlag(args[1..]) orelse default_vault_path;

    // Current passphrase
    const old_passphrase = readPassphraseTtyPrompt(allocator, "Current passphrase: ") catch {
        std.io.getStdErr().writer().print("re-seal failed: cannot open terminal\n", .{}) catch {};
        std.process.exit(1);
    };
    defer {
        std.crypto.utils.secureZero(u8, old_passphrase);
        allocator.free(old_passphrase);
    }

    // New passphrase + confirmation
    const new_passphrase = readPassphraseTtyPrompt(allocator, "New passphrase: ") catch {
        std.io.getStdErr().writer().print("re-seal failed: cannot open terminal\n", .{}) catch {};
        std.process.exit(1);
    };
    defer {
        std.crypto.utils.secureZero(u8, new_passphrase);
        allocator.free(new_passphrase);
    }
    const confirm = readPassphraseTtyPrompt(allocator, "Confirm new passphrase: ") catch {
        std.io.getStdErr().writer().print("re-seal failed: cannot open terminal\n", .{}) catch {};
        std.process.exit(1);
    };
    defer {
        std.crypto.utils.secureZero(u8, confirm);
        allocator.free(confirm);
    }

    if (!std.mem.eql(u8, new_passphrase, confirm)) {
        std.io.getStdErr().writer().print("re-seal failed: new passphrases do not match\n", .{}) catch {};
        std.process.exit(1);
    }

    // Machine ID (used if vault entry is in locked mode)
    const machine_id: ?[]u8 = probe_id.getMachineId(allocator) catch null;
    defer if (machine_id) |id| {
        std.crypto.utils.secureZero(u8, id);
        allocator.free(id);
    };

    reSealEntry(allocator, vault_path, key_name, old_passphrase, new_passphrase, machine_id) catch std.process.exit(1);
}

fn reSealEntry(
    allocator: std.mem.Allocator,
    vault_path: []const u8,
    key_name: []const u8,
    old_passphrase: []const u8,
    new_passphrase: []const u8,
    machine_id: ?[]const u8,
) !void {
    var entries = try loadVault(allocator, vault_path);
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }

    var target: ?*Entry = null;
    for (entries.items) |*e| {
        if (std.mem.eql(u8, e.key, key_name)) { target = e; break; }
    }
    const entry = target orelse return error.KeyNotFound;

    if (entry.blob.len < crypto_mod.header_size) return error.InvalidVault;
    const portable = (entry.blob[1] & crypto_mod.flag_portable) != 0;

    var stream = std.io.fixedBufferStream(entry.blob);
    const plaintext = try crypto_mod.unsealEntry(allocator, stream.reader(), old_passphrase, machine_id);
    defer {
        std.crypto.utils.secureZero(u8, plaintext);
        allocator.free(plaintext);
    }

    var new_blob_buf = std.ArrayList(u8).init(allocator);
    defer new_blob_buf.deinit();
    try crypto_mod.sealEntry(
        allocator,
        new_blob_buf.writer(),
        plaintext,
        new_passphrase,
        if (portable) null else machine_id,
        portable,
    );

    allocator.free(entry.blob);
    entry.blob = try allocator.dupe(u8, new_blob_buf.items);

    try writeVaultAtomic(allocator, vault_path, entries.items);
}

// ── unseal ────────────────────────────────────────────────────────────────────

fn cmdVerify(allocator: std.mem.Allocator, args: [][]u8) void {
    verifyInner(allocator, args) catch std.process.exit(1);
}

fn verifyEntry(
    allocator: std.mem.Allocator,
    vault_path: []const u8,
    key_name: []const u8,
    passphrase: []const u8,
    machine_id: ?[]const u8,
) !void {
    var entries = try loadVault(allocator, vault_path);
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }

    const blob: []u8 = for (entries.items) |e| {
        if (std.mem.eql(u8, e.key, key_name)) break e.blob;
    } else return error.KeyNotFound;

    var stream = std.io.fixedBufferStream(blob);
    const plaintext = try crypto_mod.unsealEntry(allocator, stream.reader(), passphrase, machine_id);
    std.crypto.utils.secureZero(u8, plaintext);
    allocator.free(plaintext);
}

fn verifyInner(allocator: std.mem.Allocator, args: [][]u8) !void {
    var use_tty = false;
    var rest = args;

    if (rest.len > 0 and std.mem.eql(u8, rest[0], "--tty")) {
        use_tty = true;
        rest = rest[1..];
    }

    if (rest.len < 1) std.process.exit(1);
    const key_name = rest[0];
    const vault_path = parseFileFlag(rest[1..]) orelse default_vault_path;

    const passphrase = if (use_tty)
        readPassphraseTty(allocator) catch std.process.exit(1)
    else
        readStdinLine(allocator) catch std.process.exit(1);
    defer {
        std.crypto.utils.secureZero(u8, passphrase);
        allocator.free(passphrase);
    }

    const machine_id: ?[]u8 = probe_id.getMachineId(allocator) catch null;
    defer if (machine_id) |id| {
        std.crypto.utils.secureZero(u8, id);
        allocator.free(id);
    };

    verifyEntry(allocator, vault_path, key_name, passphrase, machine_id) catch std.process.exit(1);
}

// Wrapper that converts any error to a silent exit(1).
fn cmdUnseal(allocator: std.mem.Allocator, args: [][]u8) void {
    unsealInner(allocator, args) catch std.process.exit(1);
}

fn unsealInner(allocator: std.mem.Allocator, args: [][]u8) !void {
    var use_tty = false;
    var rest = args;

    if (rest.len > 0 and std.mem.eql(u8, rest[0], "--tty")) {
        use_tty = true;
        rest = rest[1..];
    }

    if (rest.len < 1) std.process.exit(1);
    const key_name = rest[0];
    const vault_path = parseFileFlag(rest[1..]) orelse default_vault_path;

    // Passphrase: /dev/tty with echo-off if --tty, else stdin first line
    const passphrase = if (use_tty)
        readPassphraseTty(allocator) catch std.process.exit(1)
    else
        readStdinLine(allocator) catch std.process.exit(1);
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
    errdefer std.fs.cwd().deleteFile(tmp_path) catch {};

    {
        const tmp_file = try std.fs.cwd().createFile(tmp_path, if (comptime builtin.os.tag == .windows)
            .{}
        else
            .{ .mode = 0o600 });
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

/// Open vault read-only. On POSIX, O_NOFOLLOW prevents symlink attacks.
fn openVaultReadOnly(path: []const u8) !std.fs.File {
    if (comptime builtin.os.tag == .windows) {
        return std.fs.cwd().openFile(path, .{});
    }
    const flags: std.posix.O = .{
        .NOFOLLOW = true,
        .ACCMODE = .RDONLY,
    };
    const fd = try std.posix.open(path, flags, 0);
    return std.fs.File{ .handle = fd };
}

// ── Input helpers ─────────────────────────────────────────────────────────────

/// Read passphrase with echo disabled. Prompts "Passphrase: " on the terminal.
fn readPassphraseTty(allocator: std.mem.Allocator) ![]u8 {
    return readPassphraseTtyPrompt(allocator, "Passphrase: ");
}

fn readPassphraseTtyPrompt(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ENABLE_ECHO_INPUT: windows.DWORD = 0x0004;
        const GENERIC_READ: windows.DWORD = 0x80000000;
        const GENERIC_WRITE: windows.DWORD = 0x40000000;
        const FILE_SHARE_READ: windows.DWORD = 0x00000001;
        const FILE_SHARE_WRITE: windows.DWORD = 0x00000002;
        const OPEN_EXISTING: windows.DWORD = 3;

        const CreateFileW = struct {
            extern "kernel32" fn CreateFileW(
                lpFileName: [*:0]const u16,
                dwDesiredAccess: windows.DWORD,
                dwShareMode: windows.DWORD,
                lpSecurityAttributes: ?*anyopaque,
                dwCreationDisposition: windows.DWORD,
                dwFlagsAndAttributes: windows.DWORD,
                hTemplateFile: ?windows.HANDLE,
            ) callconv(windows.WINAPI) windows.HANDLE;
        }.CreateFileW;
        const GetConsoleMode = struct {
            extern "kernel32" fn GetConsoleMode(hConsoleHandle: windows.HANDLE, lpMode: *windows.DWORD) callconv(windows.WINAPI) windows.BOOL;
        }.GetConsoleMode;
        const SetConsoleMode = struct {
            extern "kernel32" fn SetConsoleMode(hConsoleHandle: windows.HANDLE, dwMode: windows.DWORD) callconv(windows.WINAPI) windows.BOOL;
        }.SetConsoleMode;
        const CloseHandle = struct {
            extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(windows.WINAPI) windows.BOOL;
        }.CloseHandle;
        const WriteFile = struct {
            extern "kernel32" fn WriteFile(
                hFile: windows.HANDLE,
                lpBuffer: [*]const u8,
                nNumberOfBytesToWrite: windows.DWORD,
                lpNumberOfBytesWritten: ?*windows.DWORD,
                lpOverlapped: ?*anyopaque,
            ) callconv(windows.WINAPI) windows.BOOL;
        }.WriteFile;
        const ReadFile = struct {
            extern "kernel32" fn ReadFile(
                hFile: windows.HANDLE,
                lpBuffer: [*]u8,
                nNumberOfBytesToRead: windows.DWORD,
                lpNumberOfBytesRead: ?*windows.DWORD,
                lpOverlapped: ?*anyopaque,
            ) callconv(windows.WINAPI) windows.BOOL;
        }.ReadFile;

        // Open CONIN$/CONOUT$ directly — works even when stdin/stdout are redirected.
        const conin_name = std.unicode.utf8ToUtf16LeStringLiteral("CONIN$");
        const conout_name = std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$");
        const INVALID_HANDLE = @as(windows.HANDLE, @ptrFromInt(std.math.maxInt(usize)));

        const h_in = CreateFileW(conin_name, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
        if (h_in == INVALID_HANDLE) return error.NotATty;
        defer _ = CloseHandle(h_in);

        const h_out = CreateFileW(conout_name, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
        if (h_out == INVALID_HANDLE) return error.NotATty;
        defer _ = CloseHandle(h_out);

        var mode: windows.DWORD = 0;
        if (GetConsoleMode(h_in, &mode) == 0) return error.NotATty;
        const saved_mode = mode;
        if (SetConsoleMode(h_in, mode & ~ENABLE_ECHO_INPUT) == 0) return error.NotATty;
        defer _ = SetConsoleMode(h_in, saved_mode);

        _ = WriteFile(h_out, prompt.ptr, @intCast(prompt.len), null, null);

        var buf = std.ArrayList(u8).init(allocator);
        errdefer {
            std.crypto.utils.secureZero(u8, buf.items);
            buf.deinit();
        }
        var byte: [1]u8 = undefined;
        while (buf.items.len < max_passphrase_len) {
            var n: windows.DWORD = 0;
            if (ReadFile(h_in, &byte, 1, &n, null) == 0 or n == 0) break;
            if (byte[0] == '\n' or byte[0] == '\r') break;
            try buf.append(byte[0]);
        }
        _ = WriteFile(h_out, "\r\n", 2, null, null);
        return buf.toOwnedSlice();
    }

    const tty = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
    defer tty.close();

    var tio = try std.posix.tcgetattr(tty.handle);
    const saved = tio;
    tio.lflag.ECHO = false;
    tio.lflag.ECHONL = false;
    try std.posix.tcsetattr(tty.handle, .FLUSH, tio);
    defer std.posix.tcsetattr(tty.handle, .FLUSH, saved) catch {};

    try tty.writeAll(prompt);

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

/// True when `args` is empty or only repeated `--file <path>` pairs (no stray tokens).
fn argsAreOnlyFileFlagPairs(args: [][]u8) bool {
    var i: usize = 0;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--file")) {
            if (i + 1 >= args.len) return false;
            i += 2;
        } else return false;
    }
    return true;
}

fn usageText() []const u8 {
    return (
        \\Usage:
        \\  amulet help | -h | --help
        \\  amulet version
        \\  amulet probe
        \\  amulet list                            [--file <vault>]
        \\  amulet delete             <key>       [--file <vault>]
        \\  amulet rename             <old> <new> [--file <vault>]
        \\  amulet init                            [--file <vault>]
        \\  amulet seal   [--portable] <key>       [--file <vault>]
        \\  amulet unseal [--tty]      <key>       [--file <vault>]
        \\  amulet verify [--tty]      <key>       [--file <vault>]
        \\  amulet re-seal             <key>       [--file <vault>]
        \\  amulet import  --env-file <path> [--portable] [--manifest <path>] [--wipe] [--file <vault>]
        \\
        \\  list:   key names only (one per line), no passphrase
        \\  delete: remove one key from the vault (passphrase not required)
        \\  rename: rename a key in the vault index (no passphrase, no re-encryption)
        \\  probe:  print machine ID for this host (same source as Locked-mode seal)
        \\  seal:   passphrase prompted from /dev/tty (echo off), secret read from stdin
        \\  unseal: passphrase read from stdin (first line); use --tty for interactive echo-off prompt
        \\  verify:  same as unseal but produces no output — exit 0 = correct passphrase, exit 1 = wrong
        \\  re-seal: change the passphrase for one key; prompts current + new + confirm from /dev/tty
        \\  import:  bulk-seal from a .env file (KEY=VALUE lines); --wipe overwrites values after import
        \\
    );
}

fn printUsage() void {
    std.io.getStdErr().writeAll(usageText()) catch {};
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// Create a vault in `vault_path` with a single portable entry for testing.
fn testMakeVault(
    allocator: std.mem.Allocator,
    vault_path: []const u8,
    key: []const u8,
    value: []const u8,
    passphrase: []const u8,
) !void {
    var entries = std.ArrayList(Entry).init(allocator);
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }
    var blob_buf = std.ArrayList(u8).init(allocator);
    defer blob_buf.deinit();
    try crypto_mod.sealEntry(allocator, blob_buf.writer(), value, passphrase, null, true);
    try entries.append(.{
        .key = try allocator.dupe(u8, key),
        .blob = try allocator.dupe(u8, blob_buf.items),
    });
    try writeVaultAtomic(allocator, vault_path, entries.items);
}

fn tmpVaultPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    return std.fs.path.join(allocator, &.{ dir_path, "t.vault" });
}

// ── rename ────────────────────────────────────────────────────────────────────

test "rename: key name changes, blob preserved" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const vp = try tmpVaultPath(allocator, tmp);
    defer allocator.free(vp);

    try testMakeVault(allocator, vp, "OLD", "secret", "pass");

    try renameEntryInVault(allocator, vp, "OLD", "NEW");

    var entries = try loadVault(allocator, vp);
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("NEW", entries.items[0].key);
}

test "rename: error if old key not found" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const vp = try tmpVaultPath(allocator, tmp);
    defer allocator.free(vp);

    try testMakeVault(allocator, vp, "KEY", "val", "pass");
    try std.testing.expectError(error.OldKeyNotFound, renameEntryInVault(allocator, vp, "MISSING", "NEW"));
}

test "rename: error if new key already exists" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const vp = try tmpVaultPath(allocator, tmp);
    defer allocator.free(vp);

    // Seal two entries
    var entries = std.ArrayList(Entry).init(allocator);
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }
    for ([_][]const u8{ "A", "B" }) |k| {
        var bb = std.ArrayList(u8).init(allocator);
        defer bb.deinit();
        try crypto_mod.sealEntry(allocator, bb.writer(), "v", "p", null, true);
        try entries.append(.{ .key = try allocator.dupe(u8, k), .blob = try allocator.dupe(u8, bb.items) });
    }
    try writeVaultAtomic(allocator, vp, entries.items);

    try std.testing.expectError(error.NewKeyAlreadyExists, renameEntryInVault(allocator, vp, "A", "B"));
}

// ── parseEnvPairs ─────────────────────────────────────────────────────────────

test "parseEnvPairs: basic KEY=VALUE" {
    const allocator = std.testing.allocator;
    var pairs = try parseEnvPairs(allocator, "FOO=bar\nBAZ=qux\n");
    defer pairs.deinit();
    try std.testing.expectEqual(@as(usize, 2), pairs.items.len);
    try std.testing.expectEqualStrings("FOO", pairs.items[0].key);
    try std.testing.expectEqualStrings("bar", pairs.items[0].value);
    try std.testing.expectEqualStrings("BAZ", pairs.items[1].key);
    try std.testing.expectEqualStrings("qux", pairs.items[1].value);
}

test "parseEnvPairs: skips comments and blank lines" {
    const allocator = std.testing.allocator;
    var pairs = try parseEnvPairs(allocator, "# comment\n\nKEY=val\n");
    defer pairs.deinit();
    try std.testing.expectEqual(@as(usize, 1), pairs.items.len);
    try std.testing.expectEqualStrings("KEY", pairs.items[0].key);
}

test "parseEnvPairs: value with embedded equals" {
    const allocator = std.testing.allocator;
    var pairs = try parseEnvPairs(allocator, "KEY=a=b=c\n");
    defer pairs.deinit();
    try std.testing.expectEqual(@as(usize, 1), pairs.items.len);
    try std.testing.expectEqualStrings("a=b=c", pairs.items[0].value);
}

// ── importPairs ───────────────────────────────────────────────────────────────

test "importPairs: seals entries into vault" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const vp = try tmpVaultPath(allocator, tmp);
    defer allocator.free(vp);

    const content = "FOO=hello\nBAR=world\n";
    var pairs = try parseEnvPairs(allocator, content);
    defer pairs.deinit();

    try importPairs(allocator, pairs.items, "pass", null, true, vp);

    var entries = try loadVault(allocator, vp);
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
}

test "importPairs: overwrites existing key" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const vp = try tmpVaultPath(allocator, tmp);
    defer allocator.free(vp);

    try testMakeVault(allocator, vp, "KEY", "old-value", "pass");

    var pairs = try parseEnvPairs(allocator, "KEY=new-value\n");
    defer pairs.deinit();
    try importPairs(allocator, pairs.items, "pass", null, true, vp);

    // Unseal and check new value
    var entries = try loadVault(allocator, vp);
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    var stream = std.io.fixedBufferStream(entries.items[0].blob);
    const pt = try crypto_mod.unsealEntry(allocator, stream.reader(), "pass", null);
    defer {
        std.crypto.utils.secureZero(u8, pt);
        allocator.free(pt);
    }
    try std.testing.expectEqualStrings("new-value", pt);
}

// ── verifyEntry ───────────────────────────────────────────────────────────────

test "verifyEntry: correct passphrase succeeds" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const vp = try tmpVaultPath(allocator, tmp);
    defer allocator.free(vp);

    try testMakeVault(allocator, vp, "KEY", "secret", "right");
    try verifyEntry(allocator, vp, "KEY", "right", null);
}

test "verifyEntry: wrong passphrase fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const vp = try tmpVaultPath(allocator, tmp);
    defer allocator.free(vp);

    try testMakeVault(allocator, vp, "KEY", "secret", "right");
    try std.testing.expectError(
        error.AuthenticationFailed,
        verifyEntry(allocator, vp, "KEY", "wrong", null),
    );
}

test "verifyEntry: missing key fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const vp = try tmpVaultPath(allocator, tmp);
    defer allocator.free(vp);

    try testMakeVault(allocator, vp, "KEY", "secret", "pass");
    try std.testing.expectError(
        error.KeyNotFound,
        verifyEntry(allocator, vp, "MISSING", "pass", null),
    );
}

// ── reSealEntry ───────────────────────────────────────────────────────────────

test "reSealEntry: new passphrase works, old passphrase fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const vp = try tmpVaultPath(allocator, tmp);
    defer allocator.free(vp);

    try testMakeVault(allocator, vp, "KEY", "secret", "old-pass");

    try reSealEntry(allocator, vp, "KEY", "old-pass", "new-pass", null);

    // New passphrase succeeds
    try verifyEntry(allocator, vp, "KEY", "new-pass", null);

    // Old passphrase fails
    try std.testing.expectError(
        error.AuthenticationFailed,
        verifyEntry(allocator, vp, "KEY", "old-pass", null),
    );
}

test "reSealEntry: plaintext is preserved after re-seal" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const vp = try tmpVaultPath(allocator, tmp);
    defer allocator.free(vp);

    try testMakeVault(allocator, vp, "KEY", "my-secret-value", "old");
    try reSealEntry(allocator, vp, "KEY", "old", "new", null);

    var entries = try loadVault(allocator, vp);
    defer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }
    var stream = std.io.fixedBufferStream(entries.items[0].blob);
    const pt = try crypto_mod.unsealEntry(allocator, stream.reader(), "new", null);
    defer {
        std.crypto.utils.secureZero(u8, pt);
        allocator.free(pt);
    }
    try std.testing.expectEqualStrings("my-secret-value", pt);
}

// ── parseCommand ──────────────────────────────────────────────────────────────

test "parseCommand: known commands" {
    const cases = .{
        .{ "seal", Command.seal },
        .{ "unseal", Command.unseal },
        .{ "list", Command.list },
        .{ "delete", Command.delete },
        .{ "rename", Command.rename },
        .{ "verify", Command.verify },
        .{ "re-seal", Command.re_seal },
        .{ "import", Command.import },
        .{ "probe", Command.probe },
        .{ "version", Command.version },
        .{ "init", Command.init },
        .{ "help", Command.help },
        .{ "-h", Command.help },
        .{ "--help", Command.help },
    };
    inline for (cases) |c| {
        try std.testing.expectEqual(c[1], parseCommand(c[0]).?);
    }
}

test "parseCommand: unknown command returns null" {
    try std.testing.expect(parseCommand("") == null);
    try std.testing.expect(parseCommand("re_seal") == null);
    try std.testing.expect(parseCommand("SEAL") == null);
    try std.testing.expect(parseCommand("--seal") == null);
}

// ── argsAreOnlyFileFlagPairs ──────────────────────────────────────────────────

test "argsAreOnlyFileFlagPairs: empty slice" {
    var args = [_][]u8{};
    try std.testing.expect(argsAreOnlyFileFlagPairs(&args));
}

test "argsAreOnlyFileFlagPairs: single valid pair" {
    var file_flag = "--file".*;
    var path = "x.vault".*;
    var args = [_][]u8{ &file_flag, &path };
    try std.testing.expect(argsAreOnlyFileFlagPairs(&args));
}

test "argsAreOnlyFileFlagPairs: stray token rejected" {
    var stray = "extra".*;
    var args = [_][]u8{&stray};
    try std.testing.expect(!argsAreOnlyFileFlagPairs(&args));
}

test "argsAreOnlyFileFlagPairs: --file without value rejected" {
    var file_flag = "--file".*;
    var args = [_][]u8{&file_flag};
    try std.testing.expect(!argsAreOnlyFileFlagPairs(&args));
}

// ── parseFileFlag ─────────────────────────────────────────────────────────────

test "parseFileFlag: returns path when --file is present" {
    var file_flag = "--file".*;
    var path = "my.vault".*;
    var args = [_][]u8{ &file_flag, &path };
    try std.testing.expectEqualStrings("my.vault", parseFileFlag(&args).?);
}

test "parseFileFlag: returns null when --file is absent" {
    var args = [_][]u8{};
    try std.testing.expect(parseFileFlag(&args) == null);
}

test "parseFileFlag: finds --file at end of longer arg list" {
    var key = "KEY".*;
    var file_flag = "--file".*;
    var path = "end.vault".*;
    var args = [_][]u8{ &key, &file_flag, &path };
    try std.testing.expectEqualStrings("end.vault", parseFileFlag(&args).?);
}

test "parseFileFlag: --file with no following value returns null" {
    var file_flag = "--file".*;
    var args = [_][]u8{&file_flag};
    try std.testing.expect(parseFileFlag(&args) == null);
}
