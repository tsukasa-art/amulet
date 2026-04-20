const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const id = getMachineId(allocator) catch |err| {
        std.process.exit(switch (err) {
            error.NotFound => 2,
            else => 1,
        });
    };
    defer allocator.free(id);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}\n", .{id});
}

pub fn getMachineId(allocator: std.mem.Allocator) ![]u8 {
    return switch (@import("builtin").os.tag) {
        .linux => getMachineIdLinux(allocator),
        .macos => getMachineIdMacos(allocator),
        else => error.UnsupportedPlatform,
    };
}

fn getMachineIdLinux(allocator: std.mem.Allocator) ![]u8 {
    const paths = [_][]const u8{
        "/etc/machine-id",
        "/var/lib/dbus/machine-id",
    };
    for (paths) |path| {
        const raw = std.fs.cwd().readFileAlloc(allocator, path, 64) catch continue;
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        return allocator.dupe(u8, trimmed);
    }
    return error.NotFound;
}

fn getMachineIdMacos(allocator: std.mem.Allocator) ![]u8 {
    const argv = [_][]const u8{ "ioreg", "-rd1", "-c", "IOPlatformExpertDevice" };
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 4096,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) return error.NotFound;

    return parseIoregUuid(allocator, result.stdout) orelse error.NotFound;
}

fn parseIoregUuid(allocator: std.mem.Allocator, output: []const u8) ?[]u8 {
    const needle = "\"IOPlatformUUID\" = \"";
    const start_pos = std.mem.indexOf(u8, output, needle) orelse return null;
    const uuid_start = start_pos + needle.len;
    if (uuid_start >= output.len) return null;
    const end_pos = std.mem.indexOfScalarPos(u8, output, uuid_start, '"') orelse return null;
    const uuid = output[uuid_start..end_pos];
    if (uuid.len != 36) return null; // UUID is always 8-4-4-4-12
    return allocator.dupe(u8, uuid) catch null;
}

test "parseIoregUuid extracts UUID" {
    const allocator = std.testing.allocator;
    const sample =
        \\  "IOPlatformUUID" = "6508611F-95CA-593E-9965-BE857CCFBE33"
    ;
    const result = parseIoregUuid(allocator, sample);
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("6508611F-95CA-593E-9965-BE857CCFBE33", result.?);
}

test "parseIoregUuid returns null on missing key" {
    const allocator = std.testing.allocator;
    const result = parseIoregUuid(allocator, "no uuid here");
    try std.testing.expect(result == null);
}
