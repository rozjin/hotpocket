const std = @import("std");
const fs = std.fs;
const io = std.io;
const log = std.log;

const Reader = struct {
    buf: []u8 = undefined,
    len: usize = undefined,
    pos: usize = undefined,

    const Self = @This();

    pub fn init(buf: []u8) Self {
        return Self {
            .buf = buf,
            .len = buf.len,
            .pos = 0
        };
    }

    pub fn read(self: *Self, comptime T: type) !T {
        var begin: usize = self.pos;
        var end: usize = self.pos + @sizeOf(T);

        if (begin > self.len or end > self.len) {
            return error.Overflow;
        }

        var val: T = @ptrCast(*align(1) T, self.buf[begin..end]).*;
        if (T == f32 or T == f64) {
            val = val;
        } else {
            val = @byteSwap(T, val);
        }

        self.pos = self.pos + @sizeOf(T);

        return val;
    }

    pub fn readBytes(self: *Self, read_len: usize) ![]u8 {
        var begin: usize = self.pos;
        var end: usize = self.pos + read_len;

        if (begin > self.len or end > self.len) {
            return error.Overflow;
        }

        var slice: []u8 = self.buf[begin..end];

        self.pos = self.pos + read_len;

        return slice;
    }

    pub fn readLeft(self: *Self) ![]u8 {
        return self.buf[self.pos..];
    }
};

const JClass = struct {
    pub const JConstTag = enum(u8) {
        class = 0x07,
        fieldRef = 0x09,
        methodRef = 0x0A,
        interfaceMethodRef = 0x0B,
        stringRef = 0x08,
        integer = 0x03,
        float = 0x04,
        long = 0x05,
        double = 0x06,
        nameAndType = 0x0C,
        string = 0x01,
        methodHandle = 0x0F,
        methodType = 0x10,
        dynamic = 0x11,
        invokeDynamic = 0x12,
        module = 0x13,
        package = 0x1D
    };

    pub const JConst = struct {
        tag: JConstTag,
        nameIndex: u16 = undefined,
        classIndex: u16 = undefined,
        nameAndTypeIndex: u16 = undefined,
        stringIndex: u16 = undefined,
        descIndex: u16 = undefined,
        string: []u8 = undefined,
        integer: i32 = undefined,
        long: i64 = undefined,
        float: f32 = undefined,
        double: f64 = undefined
    };

    pub const JAttributeTag = enum(u16) {
        ConstantValue,
        Code,
        StackMapTable,
        Exceptions,
        InnerClasses,
        EnclosingMethod,
        Synthetic,
        Signature,
        SourceFile,
        SourceDebugExtension,
        LineNumberTable,
        LocalVariableTable,
        LocalVariableTypeTable,
        Deprecated,
        RuntimeVisibleAnnotations,
        RuntimeInvisibleAnnotations,
        RuntimeVisibleParameterAnnotations,
        RuntimeInvisibleParameterAnnotations,
        AnnotationDefault,
        BootstrapMethods
    };

    pub const JAttribute = struct {
        name: []u8,
        data: []u8,
        tag: JAttributeTag
    };

    pub const JField = struct {
        flags: u16,
        name: []u8,
        desc: []u8,
        attributes: []JAttribute
    };

    pub const JMethod = struct {
        flags: u16,
        name: []u8,
        desc: []u8,
        attributes: []JAttribute
    };

    allocator: *std.mem.Allocator = undefined,
    buf: []u8 = undefined,
    reader: Reader = undefined,

    constant_pool: std.ArrayList(JConst) = undefined,
    interfaces: std.ArrayList([]u8) = undefined,
    fields: std.ArrayList(JField) = undefined,
    methods: std.ArrayList(JMethod) = undefined,
    attributes: std.ArrayList(JAttribute) = undefined,

    flags: u16 = undefined,
    name: []u8 = undefined,
    super: []u8 = undefined,

    magic: u32 = undefined,
    minor: u16 = undefined,
    major: u16 = undefined,

    const Self = @This();

    pub fn init(allocator: *std.mem.Allocator, buf: []u8) !Self {
        var jClass: Self = Self {
            .allocator = allocator,
            .buf = buf
        };

        jClass.reader = Reader.init(jClass.buf);
        jClass.constant_pool = std.ArrayList(JConst).init(jClass.allocator);

        jClass.magic = try jClass.reader.read(u32);

        jClass.minor = try jClass.reader.read(u16);
        jClass.major = try jClass.reader.read(u16);

        return jClass;
    }

    pub fn parseConstants(self: *Self) !void {
        var constCount: u16 = try self.reader.read(u16);

        var i: usize = 1;
        while (i < constCount) : (i = i + 1) {
            var jConst: JConst = JConst{ .tag = @intToEnum(JConstTag, try self.reader.read(u8)) };
            switch (jConst.tag) {
                .class => {
                    jConst.nameIndex = try self.reader.read(u16);
                },

                .fieldRef, .methodRef, .interfaceMethodRef => {
                    jConst.classIndex = try self.reader.read(u16);
                    jConst.nameIndex = try self.reader.read(u16);
                },

                .stringRef => {
                    jConst.stringIndex = try self.reader.read(u16);
                },

                .integer => {
                    jConst.integer = try self.reader.read(i32);
                },

                .long => {
                    jConst.long = try self.reader.read(i64);
                },

                .float => {
                    jConst.float = try self.reader.read(f32);
                },

                .double => {
                    jConst.double = try self.reader.read(f64);
                },

                .nameAndType => {
                    jConst.nameIndex = try self.reader.read(u16);
                    jConst.descIndex = try self.reader.read(u16);
                },

                .string => {
                    var stringLen = try self.reader.read(u16);
                    jConst.string = try self.reader.readBytes(stringLen);
                },

                else => {
                    log.err("[P] Unsupported Tag: {}", .{jConst.tag});
                    return error.JConstUnsupportedTag;
                }
            }

            try self.constant_pool.append(jConst);
            if (jConst.tag == JConstTag.double or jConst.tag == JConstTag.long) {
                try self.constant_pool.append(JConst{ .tag = JConstTag.integer });
                i = i + 1;
            }
        }
    }

    pub fn parseInterfaces(self: *Self) !void {
        var interfaceCount: u16 = try self.reader.read(u16);
        self.interfaces = std.ArrayList([]u8).init(self.allocator);

        var i: usize = 0;
        while (i < interfaceCount) : (i = i + 1) {
            var stringIndex: u16 = try self.reader.read(u16);
            var string: []u8 = try self.resolveString(stringIndex);
            try self.interfaces.append(string);
        }
    }

    fn parseAttributeTag(_: *Self, name: []u8) !JAttributeTag {
        var tag: ?JAttributeTag = std.meta.stringToEnum(JAttributeTag, name);
        if (tag != null) return tag.? else return error.JAttributeTagNotFound;
    }

    pub fn parseAttributes(self: *Self) !std.ArrayList(JAttribute) {
        var attributesCount: u16 = try self.reader.read(u16);
        var attributes = std.ArrayList(JAttribute).init(self.allocator);

        var i: usize = 0;
        while (i < attributesCount) : (i = i + 1) {
            try attributes.append(JAttribute{
                .name = try self.resolveString(try self.reader.read(u16)),
                .data = try self.reader.readBytes(try self.reader.read(u32)),
                .tag = undefined
            });

            attributes.items[attributes.items.len - 1].tag = try self.parseAttributeTag(attributes.items[attributes.items.len - 1].name);
        }

        return attributes;
    }

    pub fn parseFields(self: *Self) !void {
        var fieldsCount: u16 = try self.reader.read(u16);
        self.fields = std.ArrayList(JField).init(self.allocator);

        var i: usize = 0;
        while (i < fieldsCount) : (i = i + 1) {
            try self.fields.append(JField{
                .flags = try self.reader.read(u16),
                .name = try self.resolveString(try self.reader.read(u16)),
                .desc = try self.resolveString(try self.reader.read(u16)),
                .attributes = (try self.parseAttributes()).items
            });
        }
    }

    pub fn parseMethods(self: *Self) !void {
        var methodsCount: u16 = try self.reader.read(u16);
        self.methods = std.ArrayList(JMethod).init(self.allocator);

        var i: usize = 0;
        while (i < methodsCount) : (i = i + 1) {
            try self.methods.append(JMethod{
                .flags = try self.reader.read(u16),
                .name = try self.resolveString(try self.reader.read(u16)),
                .desc = try self.resolveString(try self.reader.read(u16)),
                .attributes = (try self.parseAttributes()).items
            });
        }
    }


    pub fn parseMeta(self: *Self) !void {
        self.flags = try self.reader.read(u16);

        self.name = try self.resolveString(try self.reader.read(u16));
        self.super = try self.resolveString(try self.reader.read(u16));
    }

    fn resolveString(self: *Self, index: u16) ![]u8 {
        if ((index - 1) > self.constant_pool.items.len) {
            return error.JConstIndexOutOfBounds;
        }

        var jConst: JConst = self.constant_pool.items[index - 1];
        switch (jConst.tag) {
            .string => {
                var string: []u8 = try self.allocator.alloc(u8, jConst.string.len);
                errdefer self.allocator.free(string);

                std.mem.copy(u8, string, jConst.string);

                return string;
            },

            .stringRef => {
                return self.resolveString(jConst.stringIndex);
            },

            .class, .nameAndType => {
                return self.resolveString(jConst.nameIndex);
            },

            else => {
                return error.JConstStringNotFound;
            }
        }
    }

    pub fn debugDumpInfo(self: *Self) !void {
        log.info("[K] Name => {s}", .{self.name});
        log.info("[K] Super => {s}", .{self.super});
        log.info("[K] Flags => 0x{x}", .{self.flags});

        log.info("[K] CP Size => {}", .{self.constant_pool.items.len});
        for (self.constant_pool.items) |jConst| {
            log.info("[K] CP Item Tag: 0x{x}", .{@enumToInt(jConst.tag)});
        }

        log.info("[K] IF Size => {}", .{self.interfaces.items.len});
        log.info("[K] FL Size => {}", .{self.fields.items.len});
        log.info("[K] MT Size => {}", .{self.methods.items.len});
        for (self.methods.items) |jMethod| {
           log.info("[K] MT Attributes :=> {} items", .{jMethod.attributes.len});
           for (jMethod.attributes) |jMethodAttribute| {
                log.info("[K] MT Attribute: {s}", .{@tagName(jMethodAttribute.tag)});
            }
        }

        log.info("[K] AT Size => {}", .{self.attributes.items.len});
    }
};

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

        try jClass.debugDumpInfo();

        var mixFrame: *VMFrame = try self.makeFrame(jClass, null, &[2]VMLocal{VMLocal{.int = 1}, VMLocal{ .int = 12}}, "mixOps");
        var mixResult: VMLocal = try self.execFrame(mixFrame);

        log.info("{}", .{mixResult.int});
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