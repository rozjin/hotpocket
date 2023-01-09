const std = @import("std");
const heap = std.heap;
const log = std.log;

const rangeDef = @import("range.zig");
const range = rangeDef.range;

pub const GC = struct {
    pub const Context = struct {
        pub const Obj = struct {
            marked: bool,
            val: u64,

            next: ?*Obj
        };

        stack: []*Obj,
        stack_size: u32,
        objs: ?*Obj,
        gc: *GC,

        pub fn push(self: *@This(), comptime T: type) !*T {
            if (self.stack_size + 1 > self.stack.len) {
                return error.GCStackOverflow;
            }

            const mem = self.gc.gpa.allocator();

            var val = mem.create(T);
            var obj: *Obj = try self.gc.makeObj(self, @ptrToInt(val));

            self.stack[self.stack_size] = obj;
            self.stack_size = self.stack_size + 1;

            return val;
        }

        pub fn prod(self: *@This(), val: anytype) !*@TypeOf(val) {
            var obj = try self.push(@TypeOf(val));
            obj.* = val;
            return obj;
        }

        pub fn pop(self: *@This(), comptime T: type) !*T {
            if (@as(i64, self.stack_size) - 1 < 0) {
                return error.GCStackUnderflow;
            }

            var val: u64 = self.stack[self.stack_size - 1].val;
            self.stack_size = self.stack_size - 1;

            return @intToPtr(T, val);
        }

        pub fn mark(self: *@This()) !void {
            try self.gc.markCtx(self);
        }

        pub fn sweep(self: *@This()) !void {
            try self.gc.sweepCtx(self);
        }
    };

    pub const GPAllocator = heap.GeneralPurposeAllocator(.{});
    
    gpa: GPAllocator = undefined,

    max_stack: u64 = undefined,
    max_objects: u64 = undefined,

    const Self = @This();

    pub fn init(max_objects: u64, max_stack: u64) Self {
        var gcGPA = GPAllocator{};

        return Self {
            .gpa = gcGPA,
            .max_objects = max_objects,
            .max_stack = max_stack
        };
    }

    fn makeObj(self: *Self, ctx: *Context, val: u64) !*Context.Obj {
        const mem = self.gpa.allocator();

        var obj: *Context.Obj = try mem.create(Context.Obj);
        obj.marked = false;
        obj.val = val;
        obj.next = ctx.objs;
        ctx.objs = obj;

        errdefer mem.destroy(obj);
        return obj;
    }

    pub fn make(self: *Self) !*Context {
        const mem = self.gpa.allocator();

        var ctx: *Context = try mem.create(Context);
        ctx.stack = try mem.alloc(*Context.Obj, self.max_stack);
        ctx.stack_size = 0;
        ctx.objs = null;
        ctx.gc = self;

        errdefer mem.destroy(ctx);
        errdefer mem.free(ctx.stack);
        return ctx;
    }

    pub fn del(self: *Self, ctx: *Context) !void {
        const mem = self.gpa.allocator();

        try self.clearCtx(ctx);

        mem.destroy(ctx);
    }

    fn markCtx(_: *Self, ctx: *Context) !void {
        for (range(ctx.stack_size)) |_, i| {
            if (ctx.stack[i].marked) continue;
            ctx.stack[i].marked = true;
        }
    }

    fn sweepCtx(self: *Self, ctx: *Context) !void {
        const mem = self.gpa.allocator();

        var f_obj = &(ctx.objs);
        while (f_obj.*) |obj| {
            if (obj.marked) {
                obj.marked = false;
                f_obj = &(obj.next);
            } else {
                var target = obj;

                f_obj.* = target.next;
                mem.destroy(target.val);
                mem.destroy(target);
            }
        }
    }

    fn clearCtx(self: *Self, ctx: *Context) !void {
        const mem = self.gpa.allocator();

        var f_obj = &(ctx.objs);
        while (f_obj.*) |obj| {
            var target = obj;

            f_obj.* = target.next;
            mem.destroy(target.val);
            mem.destroy(target);
        }
    }
};