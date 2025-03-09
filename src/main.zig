const std = @import("std");
const Allocator = std.mem.Allocator;
const actors = @import("actor.zig");

const Adder = @import("behaviors/Adder.zig");
const Printer = @import("behaviors/Printer.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var rand = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp()));

    var config = actors.Configuration{
        .rng = rand.random(),
        .alloc = alloc,
        .actors = .init(alloc),
        .events = .init(alloc),
    };
    defer config.deinit();

    const adder = try Adder.behavior(alloc);
    const addr_address = try adder.spawnTypedAddress(&config);

    const printer = try Printer.behavior(alloc, std.io.getStdOut());
    const addr_printer = try printer.spawnTypedAddress(&config);

    try addr_address.sendCopyConfig(&config, .{
        .left = 3,
        .right = 4,
        .send_to = addr_printer,
    });

    try addr_address.sendCopyConfig(&config, .{
        .left = 17,
        .right = 12,
        .send_to = addr_printer,
    });

    try addr_address.sendCopyConfig(&config, .{
        .left = -2_000_000_000,
        .right = -2_000_0000_000_0000,
        .send_to = addr_printer,
    });
    while (try config.step()) {}
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
