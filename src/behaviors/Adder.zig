const std = @import("std");
const actor = @import("../actor.zig");

const Allocator = std.mem.Allocator;
const Adder = @This();

pub const Message = struct {
    left: i63,
    right: i63,
    send_to: actor.TypedAddress(i64),
};

pub fn trans(
    state: *Adder,
    builder: *actor.EffectBuilder,
    msg: actor.TypedMessage(Message),
) Allocator.Error!actor.Effect {
    const res: i64 = msg.data.left + msg.data.right;
    try msg.data.send_to.send(
        builder,
        try actor.TypedMessage(i64).copy(builder.alloc, res),
    );

    return builder.finish(.{
        .state = state,
        .trans = @ptrCast(&trans),
        .deinit_fn = @ptrCast(&deinit),
    });
}

pub fn deinit(state: *Adder, alloc: Allocator) void {
    alloc.destroy(state);
}

pub fn behavior(alloc: Allocator) !actor.TypedBehavior(Adder) {
    const state = try alloc.create(Adder);
    return actor.TypedBehavior(Adder).deriveTransAndDeinit(state);
}
