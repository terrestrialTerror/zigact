const std = @import("std");
const actor = @import("../actor.zig");

const Allocator = std.mem.Allocator;
const Printer = @This();

out: std.fs.File,

pub const Message = i64;

pub fn trans(
    state: *Printer,
    builder: *actor.EffectBuilder,
    msg: actor.TypedMessage(i64),
) Allocator.Error!actor.Effect {
    state.out.writer().print("{}\n", .{msg.data.*}) catch {};

    return builder.finish(.{
        .state = state,
        .trans = @ptrCast(&trans),
        .deinit_fn = @ptrCast(&deinit),
    });
}

pub fn deinit(state: *Printer, alloc: Allocator) void {
    state.out.close();
    alloc.destroy(state);
}

pub fn behavior(alloc: Allocator, out: std.fs.File) !actor.TypedBehavior(@This()) {
    const state = try alloc.create(@This());
    state.* = .{
        .out = out,
    };
    return actor.TypedBehavior(@This()).deriveTransAndDeinit(state);
}
