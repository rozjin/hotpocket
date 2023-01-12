const std = @import("std");
const heap = std.heap;
const io = std.io;
const log = std.log;
const mem = std.mem;

const jReaderDef = @import("reader.zig");
const jClassDef = @import("class.zig");
const rangeDef = @import("range.zig");

const range = rangeDef.range;
const stringToEnum = std.meta.stringToEnum;

const Reader = jReaderDef.Reader;

const JClass = jClassDef.JClass;

const JAttribute = JClass.JAttribute;
const JAttributeTag = JClass.JAttributeTag;
const JCode = JAttribute.JCode;

const JConst = JClass.JConst;
const JConstTag = JClass.JConstTag;
const JField = JClass.JField;
const JMethod = JClass.JMethod;

pub const JClassParser = struct {
    const Self = @This();
    const JMagic = 0xCAFEBABE;

    jClassArena: heap.ArenaAllocator = undefined,
    parserArena: heap.ArenaAllocator = undefined,

    pub fn init() Self {
        var jClassArena = heap.ArenaAllocator
                .init(heap.page_allocator);
        var parserArena = heap.ArenaAllocator
                .init(heap.page_allocator);

        return Self {
            .jClassArena = jClassArena,
            .parserArena = parserArena
        };
    }

    pub fn parseClass(self: *Self, buf: []u8) !JClass {
        const allocator = self.parserArena.allocator();
        var reader: *Reader = try allocator.create(Reader);
        defer allocator.destroy(reader);
        reader.* = Reader.init(buf);

        var magic: u32 = try reader.read(u32);
        if (magic != JMagic) {
            log.err("[P] Bad magic number {x}", .{magic});
            return error.JBadMagicNumber;
        }

        const jClassAllocator = self.jClassArena.allocator();

        var jClass: *JClass = try jClassAllocator.create(JClass);
        defer jClassAllocator.destroy(jClass);
        
        try self.parseMagic(jClass, reader);
        try self.parseConstants(jClass, reader);
        try self.parseMeta(jClass, reader);
        try self.parseInterfaces(jClass, reader);

        try self.parseFields(jClass, reader);
        try self.parseMethods(jClass, reader);

        try self.parseClassAttributes(jClass, reader);

        return jClass.*;
    }

    fn parseMagic(_: *Self,
                jClass: *JClass, reader: *Reader) !void {
        jClass.magic = JMagic;
        jClass.minor = try reader.read(u16);
        jClass.major = try reader.read(u16);
    }

    fn parseConstants(self: *Self,
                jClass: *JClass, reader: *Reader) !void {
        const allocator = self.parserArena.allocator();

        var constCount: u16 = try reader.read(u16);
        var constant_pool = std.ArrayList(JConst).init(allocator);
        defer constant_pool.deinit();

        var i: usize = 1;
        while (i < constCount) : (i = i + 1) {
            var jConst: JConst = JConst{ .tag = @intToEnum(JConstTag, try reader.read(u8)) };
            switch (jConst.tag) {
                .class, .module, .package => jConst.nameIndex = try reader.read(u16),

                .fieldRef, .methodRef, .interfaceMethodRef => {
                    jConst.classIndex = try reader.read(u16);
                    jConst.nameIndex = try reader.read(u16);
                },

                .stringRef => jConst.stringIndex = try reader.read(u16),
                .integer => jConst.integer = try reader.read(i32),
                .long => jConst.long = try reader.read(i64),
                .float => jConst.float = try reader.read(f32),
                .double => jConst.double = try reader.read(f64),

                .nameAndType => {
                    jConst.nameIndex = try reader.read(u16);
                    jConst.descIndex = try reader.read(u16);
                },

                .string => {
                    var string_len = try reader.read(u16);
                    jConst.string = try reader.readBytes(string_len);
                },

                .methodHandle => {
                    jConst.refKind = try reader.read(u8);
                    jConst.refIndex = try reader.read(u16);
                },

                .methodType => {
                    jConst.descIndex = try reader.read(u16);
                },

                .varDynamic, .invokeDynamic => {
                    jConst.bootstrapIndex = try reader.read(u16);
                    jConst.nameAndTypeIndex = try reader.read(u16);
                }
            }

            try constant_pool.append(jConst);
            if (jConst.tag == JConstTag.double or jConst.tag == JConstTag.long) {
                try constant_pool.append(JConst{ .tag = JConstTag.integer });
                i = i + 1;
            }
        }

        jClass.constant_pool = try constant_pool.toOwnedSlice();
    }

    fn parseMeta(self: *Self,
                jClass: *JClass, reader: *Reader) !void {
        jClass.flags = try reader.read(u16);

        var nameIndex: u16 = try reader.read(u16);
        jClass.name = try self.resolveString(nameIndex, jClass, reader);

        var superIndex: u16 = try reader.read(u16);
        if (superIndex > 0) {
            jClass.super = try self.resolveString(superIndex, jClass, reader);
        } else {
            jClass.super = &[_]u8 {};
        }
    }

    fn parseInterfaces(self: *Self,
                jClass: *JClass, reader: *Reader) !void {
        const allocator = self.parserArena.allocator();

        var interfaceCount: u16 = try reader.read(u16);
        var interfaces = std.ArrayList([]u8).init(allocator);
        defer interfaces.deinit();

        for (range(interfaceCount)) |_| {
            var stringIndex: u16 = try reader.read(u16);
            var string: []u8 = try self.resolveString(stringIndex, jClass, reader);
            try interfaces.append(string);
        }

        jClass.interfaces = try interfaces.toOwnedSlice();
    }

    fn parseAttributeTag(_: *Self, name: []u8) ?JAttributeTag {
        return stringToEnum(JAttributeTag, name);
    }

    fn parseErrorFns(self: *Self,
                jClass: *JClass, reader: *Reader) ![]JCode.JErrorFn {
        const allocator = self.parserArena.allocator();

        var errorFnCount: u16 = try reader.read(u16);
        var errorFns = std.ArrayList(JCode.JErrorFn).init(allocator);
        defer errorFns.deinit();

        for (range(errorFnCount)) |_| {
            var errorFn: JCode.JErrorFn = .{
                .startPc = try reader.read(u16),
                .endPc = try reader.read(u16),
                .handlerPc = try reader.read(u16)
            };

            var catchKindIndex: u16 = try reader.read(u16);
            if (catchKindIndex > 0) errorFn.catchKind = jClass.constant_pool[catchKindIndex - 1];

            try errorFns.append(errorFn);
        }

        return try errorFns.toOwnedSlice();
    }

    fn parseAttributes(self: *Self,
                jClass: *JClass, reader: *Reader) ![]JAttribute {
        const allocator = self.parserArena.allocator();

        var attributesCount: u16 = try reader.read(u16);
        var attributes = std.ArrayList(JAttribute).init(allocator);
        defer attributes.deinit();

        for (range(attributesCount)) |_| {
            var jAttributeTag = self.parseAttributeTag(try self.resolveString(try reader.read(u16), jClass, reader));
            var jAttributeLen = try reader.read(u32);
            if (jAttributeTag == null) {
                _ = try reader.readBytes(jAttributeLen);
                continue;
            }

            var jAttribute: JAttribute = JAttribute {
                .tag = jAttributeTag.?,
                .len = jAttributeLen
            };

            switch (jAttribute.tag) {
                .ConstantValue => jAttribute.jConst = try reader.read(u16),

                .Code => {
                    jAttribute.jCode = JCode{
                        .maxStack = try reader.read(u16),
                        .maxLocals = try reader.read(u16),

                        .code = try reader.readBytes(try reader.read(u32)),
                        .exceptions = try self.parseErrorFns(jClass, reader),
                        .attributes = try self.parseAttributes(jClass, reader)
                    };
                },

                .Exceptions => {
                    var errorCount: u16 = try reader.read(u16);
                    var errors = std.ArrayList(JConst).init(allocator);
                    defer errors.deinit();

                    for (range(errorCount)) |_| {
                        try errors.append(jClass.constant_pool[try reader.read(u16) - 1]);
                    }

                    jAttribute.jErrors = try errors.toOwnedSlice();
                },

                .InnerClasses => {
                    var innerClassesCount: u16 = try reader.read(u16);
                    var innerClasses = std.ArrayList(JAttribute.JInnerClass).init(allocator);
                    defer innerClasses.deinit();

                    for (range(innerClassesCount)) |_| {
                        var innerInfoIndex = try reader.read(u16) - 1;
                        var outerInfoIndex = try reader.read(u16);
                        if (outerInfoIndex > 0) outerInfoIndex = outerInfoIndex - 1;
                        if (outerInfoIndex == innerInfoIndex) return error.JInvalidInnerClass;

                        var innerClass: JAttribute.JInnerClass = .{
                            .innerInfoIndex = innerInfoIndex,
                            .outerInfoIndex = outerInfoIndex,
                        };

                        var innerNameIndex: u16 = try reader.read(u16);
                        if (innerNameIndex > 0) innerClass.innerNameIndex = innerNameIndex;
                        innerClass.innerAccessFlag = try reader.read(u16);                   

                        try innerClasses.append(innerClass);
                    }

                    jAttribute.jInnerClasses = try innerClasses.toOwnedSlice();
                },

                .EnclosingMethod => {
                    jAttribute.jEnclosingMethod = JAttribute.JEnclosingMethod{
                        .classIndex = try reader.read(u16),
                        .methodIndex = try reader.read(u16)
                    };
                },

                .Synthetic => jAttribute.jSynthetic = true,
                .Signature => jAttribute.jSignature = try reader.read(u16),
                .SourceFile => jAttribute.jSource = try reader.read(u16),

                else => {
                    _ = try reader.readBytes(jAttribute.len);
                }
            }

            try attributes.append(jAttribute);
        }

        return try attributes.toOwnedSlice();
    }

    fn parseClassAttributes(self: *Self,
                jClass: *JClass, reader: *Reader) !void {
        jClass.attributes = try self.parseAttributes(jClass, reader);
    }

    fn parseFields(self: *Self,
                jClass: *JClass, reader: *Reader) !void {
        const allocator = self.parserArena.allocator();

        var fieldsCount: u16 = try reader.read(u16);
        var fields = std.ArrayList(JField).init(allocator);
        defer fields.deinit();

        for (range(fieldsCount)) |_| {
            try fields.append(JField{
                .flags = try reader.read(u16),
                .name = try self.resolveString(try reader.read(u16), jClass, reader),
                .desc = try self.resolveString(try reader.read(u16), jClass, reader),
                .attributes = try self.parseAttributes(jClass, reader)
            });
        }

        jClass.fields = try fields.toOwnedSlice();
    }

    fn parseMethods(self: *Self,
                jClass: *JClass, reader: *Reader) !void {
        const allocator = self.parserArena.allocator();

        var methodsCount: u16 = try reader.read(u16);
        var methods = std.ArrayList(JMethod).init(allocator);
        methods.deinit();

        for (range(methodsCount)) |_| {
            try methods.append(JMethod{
                .flags = try reader.read(u16),
                .name = try self.resolveString(try reader.read(u16), jClass, reader),
                .desc = try self.resolveString(try reader.read(u16), jClass, reader),
                .attributes = try self.parseAttributes(jClass, reader)
            });
        }

        jClass.methods = try methods.toOwnedSlice();
    }

    fn resolveString(self: *Self, index: u16,
                jClass: *JClass, reader: *Reader) ![]u8 {
        if ((index - 1) > jClass.constant_pool.len or
            index <= 0) {
            return error.JConstIndexOutOfBounds;
        }

        const allocator = self.parserArena.allocator();

        var jConst: JConst = jClass.constant_pool[index - 1];
        switch (jConst.tag) {
            .string => {
                var string: []u8 = try allocator.alloc(u8, jConst.string.len);
                errdefer allocator.free(string);

                std.mem.copy(u8, string, jConst.string);

                return string;
            },

            .stringRef => {
                return self.resolveString(jConst.stringIndex, jClass, reader);
            },

            .class, .nameAndType => {
                return self.resolveString(jConst.nameIndex, jClass, reader);
            },

            else => {
                return error.JConstStringNotFound;
            }
        }
    }
};