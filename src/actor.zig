const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Message = packed struct {
    data: *anyopaque,
    deinit: *const fn (*anyopaque, Allocator) void,

    pub fn reify(this: @This(), S: type) TypedMessage(S) {
        return @bitCast(this);
    }
};

pub fn TypedMessage(S: type) type {
    return packed struct {
        data: *S,
        deinit: *const fn (*S, Allocator) void,

        fn deinitVoid(data: *S, alloc: Allocator) void {
            _ = alloc;
            _ = data;
        }

        fn deinitCopy(data: *S, alloc: Allocator) void {
            alloc.destroy(data);
        }

        pub fn copy(alloc: Allocator, data: S) Allocator.Error!TypedMessage(S) {
            const data_ptr = try alloc.create(S);
            data_ptr.* = data;
            return .{
                .data = data_ptr,
                .deinit = &deinitCopy,
            };
        }

        pub fn withoutDeinit(data: *S) TypedMessage(S) {
            return .{
                .data = data,
                .deinit = &deinitVoid,
            };
        }

        pub fn withDeinit(data: *S) TypedMessage(S) {
            return .{
                .data = data,
                .deinit = &S.deinit,
            };
        }

        pub fn erase(this: @This()) Message {
            return .{
                .data = @ptrCast(this.data),
                .deinit = @ptrCast(this.deinit),
            };
        }
    };
}

pub const Address = u128;

pub fn TypedAddress(M: type) type {
    return packed struct {
        addr: Address,
        pub fn send(this: @This(), builder: *EffectBuilder, msg: TypedMessage(M)) Allocator.Error!void {
            try builder.send(this.addr, msg.erase());
        }

        pub fn sendCopy(this: @This(), builder: *EffectBuilder, msg: M) Allocator.Error!void {
            try builder.send(this.addr, TypedMessage(M).copy(
                builder.alloc,
                msg,
            ));
        }

        pub fn sendConfig(this: @This(), config: *Configuration, msg: TypedMessage(M)) Allocator.Error!void {
            try config.events.append(.{
                .message = msg.erase(),
                .target = this.addr,
            });
        }

        pub fn sendCopyConfig(this: @This(), config: *Configuration, msg: M) Allocator.Error!void {
            try config.events.append(.{
                .message = (try TypedMessage(M).copy(config.alloc, msg)).erase(),
                .target = this.addr,
            });
        }
    };
}

pub const Actor = struct {
    address: Address,
    behavior: Behavior,
};

pub const Event = struct {
    target: Address,
    message: Message,
};

pub const EffectBuilder = struct {
    rng: std.Random.DefaultPrng,
    alloc: Allocator,
    actors: std.ArrayList(Actor),
    events: std.ArrayList(Event),

    pub fn init(alloc: Allocator, seed: u64) EffectBuilder {
        return .{
            .alloc = alloc,
            .actors = std.ArrayList(Actor).init(alloc),
            .events = std.ArrayList(Event).init(alloc),
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn deinit(this: *@This()) void {
        this.actors.deinit();
        this.events.deinit();
    }

    pub fn spawnActor(this: *@This(), behavior: Behavior) Allocator.Error!Address {
        const addr = this.rng.random().int(Address);
        const actor = Actor{
            .addr = addr,
            .behavior = behavior,
        };
        try this.actors.append(actor);
        return actor;
    }

    pub fn send(this: *@This(), address: Address, message: Message) Allocator.Error!void {
        try this.events.append(.{
            .target = address,
            .message = message,
        });
    }

    pub fn finish(this: *@This(), next_behavior: Behavior) Effect {
        return .{
            .actors = this.actors.items,
            .events = this.events.items,
            .next_behavior = next_behavior,
        };
    }
};

pub fn TypedBehavior(S: type) type {
    return struct {
        state: *S,
        trans: *const fn (*S, *EffectBuilder, Message) Allocator.Error!Effect,
        deinit_fn: *const fn (*S, Allocator) void,

        pub fn spawnTypedAddress(this: @This(), config: *Configuration) !TypedAddress(S.Message) {
            const addr = try config.spawnActor(this.erase());
            return TypedAddress(S.Message){ .addr = addr };
        }

        pub fn deriveTrans(state: *S, deinit_fn: *const fn (*S) void) @This() {
            return .{
                .state = state,
                .trans = @ptrCast(&S.trans),
                .deinit_fn = deinit_fn,
            };
        }

        pub fn deriveDeinit(state: *S, trans: *const fn (*S, *EffectBuilder, Message) Allocator.Error!Effect) @This() {
            return .{
                .state = state,
                .trans = &trans,
                .deinit_fn = &S.deinit,
            };
        }

        pub fn deriveTransAndDeinit(state: *S) @This() {
            return .{
                .state = state,
                .trans = @ptrCast(&S.trans),
                .deinit_fn = &S.deinit,
            };
        }

        pub fn erase(this: @This()) Behavior {
            return .{
                .state = @ptrCast(this.state),
                .trans = @ptrCast(this.trans),
                .deinit_fn = @ptrCast(this.deinit_fn),
            };
        }
    };
}

pub const Behavior = struct {
    state: *anyopaque,
    trans: *const fn (*anyopaque, *EffectBuilder, Message) Allocator.Error!Effect,
    deinit_fn: *const fn (*anyopaque, Allocator) void,

    pub fn reify(this: @This(), S: type) TypedBehavior(S) {
        return .{
            .state = @ptrCast(this.state),
            .trans = @ptrCast(this.trans),
            .deinit_fn = @ptrCast(this.deinit_fn),
        };
    }

    pub fn call(this: @This(), builder: *EffectBuilder, message: Message) Allocator.Error!Effect {
        return this.trans(this.state, builder, message);
    }

    pub fn deinit(this: @This(), allocator: Allocator) void {
        this.deinit_fn(this.state, allocator);
    }
};

pub const Configuration = struct {
    const ActorHashMap = std.AutoHashMap(Address, Behavior);
    actors: ActorHashMap,
    events: std.ArrayList(Event),
    // okay we're done with therory, lets get practical
    alloc: Allocator,
    rng: std.Random,

    pub fn deinit(this: @This()) void {
        var actor_iter = this.actors.iterator();
        while (actor_iter.next()) |entry| {
            entry.value_ptr.deinit(this.alloc);
        }
        for (this.events.items) |event| {
            event.message.deinit(event.message.data, this.alloc);
        }
        var acts = this.actors;
        acts.deinit();
        var vent = this.events;
        vent.deinit();
    }

    pub fn spawnActor(this: *@This(), behavior: Behavior) !Address {
        const addr: u128 = this.rng.int(Address);
        try this.actors.put(addr, behavior);
        return addr;
    }

    // returns a boolean if there are elements left.
    // this should be an atomic operation so you can retry after failing to allocate.
    pub fn step(this: *@This()) !bool {
        if (this.events.items.len != 0) {
            // when an allocation error occurs we need to make sure the state of everything does not update.
            // code didn't complete the way it should so we need to keep that in tact.
            // rng is allowed to change, but you should be able to immediatly retry the step function
            // without anything relevant changing.
            const index = this.rng.intRangeAtMost(usize, 0, this.events.items.len - 1);

            const event = this.events.items[index];
            var effect_builder = EffectBuilder.init(this.alloc, this.rng.int(u64));
            defer effect_builder.deinit();
            // there's some cases where this will legitimatly be empty
            // either the address itself was completely fabircated
            // or the actor cleaned itself up. in either case the
            // correct action is to disregard the current event.
            if (this.actors.getEntry(event.target)) |behavior| {
                const effect = try behavior.value_ptr.call(&effect_builder, event.message);
                errdefer {
                    // it can still fail after this, so we have to clean up
                    // just in case memory fails to allocate
                    for (effect.actors) |actor| {
                        actor.behavior.deinit(this.alloc);
                    }
                    for (effect.events) |new_event| {
                        const msg = new_event.message;
                        msg.deinit(msg.data, this.alloc);
                    }
                }
                if (effect.actors.len < std.math.maxInt(ActorHashMap.Size)) {
                    try this.actors.ensureTotalCapacity(@intCast(effect.actors.len));
                } else {
                    return error.TooManyActors;
                }
                // note, indecies into the array are not invalidated if
                // the array needs to grow as the elements are memcopy'd
                // thus preserving order.
                try this.events.ensureTotalCapacity(effect.events.len);

                // everything after this will succeed
                // lets complete this atomic operation.

                // when cleaning up or transitioning, the
                // actor manages it's own memory, so all that's
                // left at this point is to assign the new behavior
                if (effect.next_behavior) |next_behavior| {
                    behavior.value_ptr.* = next_behavior;
                } else {
                    _ = this.actors.remove(behavior.key_ptr.*);
                }

                this.events.appendSlice(effect.events) catch unreachable;
                for (effect.actors) |actor| {
                    this.actors.put(actor.address, actor.behavior) catch unreachable;
                }
            }
            // nothing will fail after this point so we can destroy the event from here.
            const msg = this.events.swapRemove(index).message;
            msg.deinit(msg.data, this.alloc);

            return this.events.items.len != 0;
        } else {
            return false;
        }
    }
};

pub const Effect = struct {
    actors: []const Actor,
    events: []const Event,
    next_behavior: ?Behavior,
};
