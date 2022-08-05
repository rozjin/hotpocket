const std = @import("std");
const fs = std.fs;
const io = std.io;
const log = std.log;

pub const VM = struct {
    const VMError = error {
        Internal,
        OutOfMemory,
        StackOverflow,
        Unknown
    };

    pub const VMNull: u64 = 0x1;

    pub const VMLocal = union(enum) {
        byte: i8,
        short: i16,
        int: i32,
        long: i64,
        float: f32,
        double: f64,
        boolean: bool,
        ref: ?*GC.GCObject,
    };

    pub const VMFrame = struct {
        method: *JClass.JMethod,
        class: *JClass,
        ip: u32,
        code: []u8,
        locals: []VMLocal,
        stack: []VMLocal,
        stackTop: usize,
        obj: ?*GC.GCObject
    };

    buf: []u8 = undefined,
    allocator: *std.mem.Allocator = undefined,
    reader: Reader = undefined,

    const Self = @This();

    pub fn init(self: *Self, classfile_path: []const u8) !void {
        var dir: fs.Dir = fs.cwd();
        var classfile: fs.File = try dir.openFile(classfile_path, .{});

        var classtat: fs.File.Stat = try classfile.stat();
        var classize: usize = classtat.size;

        self.allocator = &std.heap.ArenaAllocator.init(std.heap.page_allocator).allocator;

        self.buf = try self.allocator.alloc(u8, classize);
        defer self.allocator.free(self.buf);

        _ = try classfile.read(self.buf);
        self.reader = Reader.init(self.buf);

        var magic: u32 = try self.reader.read(u32);
        if (magic != 0xCAFEBABE) {
            log.err("[P] Bad magic number {x}", .{magic});
            return error.JBadMagicNumber;
        }

        var jClassAllocator: *std.mem.Allocator = &std.heap.ArenaAllocator.init(std.heap.page_allocator).allocator;
        var jClass: *JClass = try self.allocator.create(JClass);
        jClass.* = try JClass.init(jClassAllocator, self.buf);

        try jClass.parseConstants();
        try jClass.parseMeta();
        try jClass.parseInterfaces();

        try jClass.parseFields();
        try jClass.parseMethods();

        jClass.attributes = try jClass.parseAttributes();
    }

    fn makeObject(self: *Self, jClass: *JClass) void {

    }

    fn findMethod(self: *Self, jClass: *JClass, name: []const u8) !*JClass.JMethod {
        for (jClass.methods.items) |jMethodRef, index| {
            if (std.mem.eql(u8, jMethodRef.name, name)) {
                return &jClass.methods.items[index];
            }
        }

        return error.JClassMethodNotFound;
    }

    fn makeFrame(self: *Self, jClass: *JClass, jObject: ?*GC.GCObject, args: []const VMLocal, name: []const u8) !*VMFrame {
        var jMethod: *JClass.JMethod = try self.findMethod(jClass, name);
        var methodFrame: *VMFrame = try self.allocator.create(VMFrame);
        errdefer self.allocator.destroy(methodFrame);
        methodFrame.* = VMFrame{
            .method = jMethod,
            .class = jClass,
            .ip = 0,
            .code = &[_]u8{},
            .locals = &[_]VMLocal{},
            .stack = &[_]VMLocal{},
            .stackTop = 0,
            .obj = jObject
        };

        for (jMethod.attributes) |jMethodAttribute| {
            switch (jMethodAttribute.tag) {
                .Code => {
                    var codeReader: Reader = Reader.init(jMethodAttribute.data);
                    var maxStack: u16 = try codeReader.read(u16);
                    var maxLocals: u16 = try codeReader.read(u16);
                    var length: u32 = try codeReader.read(u32);

                    var code: []u8 = try codeReader.readLeft();

                    methodFrame.locals = try self.allocator.alloc(VMLocal, maxLocals);
                    methodFrame.stack = try self.allocator.alloc(VMLocal, maxStack);
                    methodFrame.code = try self.allocator.alloc(u8, code.len);

                    errdefer self.allocator.free(methodFrame.locals);
                    errdefer self.allocator.free(methodFrame.stack);
                    errdefer self.allocator.free(methodFrame.code);

                    std.mem.copy(u8, methodFrame.code, code);
                    std.mem.copy(VMLocal, methodFrame.locals, args);
                },

                else => {
                    log.warn("[W] Unsupported Method Attribute: {s}", .{@tagName(jMethodAttribute.tag)});
                }
            }
        }

        if (methodFrame.code.len > 1) return methodFrame else return error.VMCouldNotMakeFrame;
    }

    fn push(frame: *VMFrame, val: VMLocal) !void {
        if (frame.stackTop == frame.stack.len) {
            return error.VMStackOverflow;
        }

        frame.stack[frame.stackTop] = val;
        frame.stackTop = frame.stackTop + 1;
    }

    fn pop(frame: *VMFrame) !VMLocal {
        if (frame.stackTop == 0) {
            return error.VMStackUnderflow;
        }

        frame.stackTop = frame.stackTop - 1;
        var val: VMLocal = frame.stack[frame.stackTop];
        return val;
    }

    fn execFrame(self: *Self, frame: *VMFrame) !VMLocal {
        while (true) : (frame.ip = frame.ip + 1) {
            var op: u8 = frame.code[frame.ip];

            log.info("op: {}", .{op});

            switch (op) {
                0x36, 0x15 => {
                    switch(op) {
                        0x36 => frame.locals[frame.code[frame.ip + 1]] = try pop(frame),
                        0x15 => try push(frame, frame.locals[frame.code[frame.ip + 1]]),
                        else => {}
                    }

                    frame.ip = frame.ip + 1;
                },

                0x1A => try push(frame, frame.locals[0]),
                0x1B => try push(frame, frame.locals[1]),
                0x1C => try push(frame, frame.locals[2]),
                0x1D => try push(frame, frame.locals[3]),

                0x60 => {
                    var other: VMLocal = try pop(frame);
                    frame.stack[frame.stackTop - 1].int += other.int;
                },

                0x64 => {
                    var other: VMLocal = try pop(frame);
                    frame.stack[frame.stackTop - 1].int -= other.int;
                },

                0x68 => {
                    var other: VMLocal = try pop(frame);
                    frame.stack[frame.stackTop - 1].int *= other.int;
                },

                0x6C => {
                    var other: VMLocal = try pop(frame);
                    if (other.int == 0) {
                        unreachable;
                    }

                    frame.stack[frame.stackTop - 1].int = @divFloor(frame.stack[frame.stackTop - 1].int, other.int);
                },

                0x7E => {
                    var other: VMLocal = try pop(frame);
                    frame.stack[frame.stackTop - 1].int &= other.int;
                },

                0x2, 0x3, 0x4, 0x5, 0x6, 0x7, 0x8 => {
                    if (op == 0x2) {
                        try push(frame, VMLocal{ .int = -1 });
                        break;
                    }

                    try push(frame, VMLocal{ .int = op - 3 });
                },

                0x1 => {
                    try push(frame, VMLocal{ .ref = null });
                },

                0x74 => {
                    frame.stack[frame.stackTop - 1].int = 0 - frame.stack[frame.stackTop - 1].int;
                },

                0x80 => {
                    var other: VMLocal = try pop(frame);
                    frame.stack[frame.stackTop - 1].int |= other.int;
                },

                0x70 => {
                    var other: VMLocal = try pop(frame);
                    frame.stack[frame.stackTop - 1].int = @rem(frame.stack[frame.stackTop - 1].int, other.int);
                },

                0xAC => return try pop(frame),

                0x3B => frame.locals[0] = try pop(frame),
                0x3C => frame.locals[1] = try pop(frame),
                0x3D => frame.locals[2] = try pop(frame),
                0x3E => frame.locals[3] = try pop(frame),       

                else => log.info("[K] Unsupported opcode: {}", .{op})
            }
        }

        return error.VMNoReturn;
    }
};