const std = @import("std");
const io = std.io;
const log = std.log;
const mem = std.mem;

const jReaderDef = @import("reader.zig");
const jClassDef = @import("class.zig");
const rangeDef = @import("range.zig");

const range = rangeDef.range;

const Reader = jReaderDef.Reader;

const JClass = jClassDef.JClass;
const JAttribute = JClass.JAttribute;
const JAttributeTag = JClass.JAttributeTag;
const JConst = JClass.JConst;
const JConstTag = JClass.JConstTag;
const JField = JClass.JField;
const JMethod = JClass.JMethod;

pub const JClassParser = struct {
    jClassArena: std.heap.ArenaAllocator = undefined,
    parserArena: std.heap.ArenaAllocator = undefined,

    const Self = @This();
    const JMagic = 0xCAFEBABE;

    pub fn init() Self {
        return Self {
            .jClassArena = std.heap.ArenaAllocator
                .init(std.heap.page_allocator),
            .parserArena = std.heap.ArenaAllocator
                .init(std.heap.page_allocator)
        };
    }

    fn allocator(self: *Self) *std.mem.Allocator {
        return &self.parserArena.allocator;
    }

    fn jClassAllocator(self: *Self) *std.mem.Allocator {
        return &self.jClassArena.allocator;
    }

    pub fn parseClass(self: *Self, buf: []u8) !JClass {
        var reader: *Reader = &Reader.init(buf);

        var magic: u32 = try reader.read(u32);
        if (magic != JMagic) {
            log.err("[P] Bad magic number {x}", .{magic});
            return error.JBadMagicNumber;
        }

        var jClass: *JClass = try self.jClassAllocator().create(JClass);
        defer self.jClassAllocator().destroy(jClass);

        try self.parseMagic(jClass, reader);
        try self.parseConstants(jClass, reader);
        try self.parseMeta(jClass, reader);
        try self.parseInterfaces(jClass, reader);

        try self.parseFields(jClass, reader);
        try self.parseMethods(jClass, reader);

        try self.parseAttributes(jClass, reader);

        return jClass.*;
    }

    fn parseMagic(self: *Self,
                jClass: *JClass, reader: *Reader) !void {
        jClass.magic = JMagic;
        jClass.minor = try reader.read(u16);
        jClass.major = try reader.read(u16);
    }

    fn parseConstants(self: *Self,
                jClass: *JClass, reader: *Reader) !void {
        var constCount: u16 = try reader.read(u16);
        var constant_pool = std.ArrayList(JConst).init(self.allocator());
        defer constant_pool.deinit();

        var i: usize = 1;
        while (i < constCount) : (i = i + 1) {
            var jConst: JConst = JConst{ .tag = @intToEnum(JConstTag, try reader.read(u8)) };
            switch (jConst.tag) {
                .class, .module, .package => {
                    jConst.nameIndex = try reader.read(u16);
                },

                .fieldRef, .methodRef, .interfaceMethodRef => {
                    jConst.classIndex = try reader.read(u16);
                    jConst.nameIndex = try reader.read(u16);
                },

                .stringRef => {
                    jConst.stringIndex = try reader.read(u16);
                },

                .integer => {
                    jConst.integer = try reader.read(i32);
                },

                .long => {
                    jConst.long = try reader.read(i64);
                },

                .float => {
                    jConst.float = try reader.read(f32);
                },

                .double => {
                    jConst.double = try reader.read(f64);
                },

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

        jClass.constant_pool = constant_pool.toOwnedSlice();
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
            jClass.super = @as([*]u8, undefined)[0];
        }
    }

    fn parseInterfaces(self: *Self,
                jClass: *JClass, reader: *Reader) !void {
        var interfaceCount: u16 = try reader.read(u16);
        var interfaces = std.ArrayList([]u8).init(self.allocator());
        defer interfaces.deinit();

        for (range(interfaceCount)) |_, i| {
            var stringIndex: u16 = try reader.read(u16);
            var string: []u8 = try self.resolveString(stringIndex, jClass, reader);
            try interfaces.append(string);
        }

        jClass.interfaces = interfaces.toOwnedSlice();
    }

    fn parseAttributeTag(_: *Self, name: []u8) !JAttributeTag {
        var tag: ?JAttributeTag = std.meta.stringToEnum(JAttributeTag, name);
        if (tag != null) return tag.? else return error.JAttributeTagNotFound;
    }

    fn parseSubAttributes(self: *Self,
                jClass: *JClass, reader: *Reader) ![]JAttribute {
        var attributesCount: u16 = try reader.read(u16);
        var attributes = std.ArrayList(JAttribute).init(self.allocator());
        defer attributes.deinit();

        for (range(attributesCount)) |_, i| {
            try attributes.append(JAttribute{
                .name = try self.resolveString(try reader.read(u16), jClass, reader),
                .data = try reader.readBytes(try reader.read(u32)),
                .tag = undefined
            });

            attributes.items[attributes.items.len - 1].tag = try self.parseAttributeTag(attributes.items[attributes.items.len - 1].name);
        }

        return attributes.toOwnedSlice();
    }

    fn parseAttributes(self: *Self,
                jClass: *JClass, reader: *Reader) !void {
        var attributes = try self.parseSubAttributes(jClass, reader);
        jClass.attributes = attributes;
    }

    fn parseFields(self: *Self,
                jClass: *JClass, reader: *Reader) !void {
        var fieldsCount: u16 = try reader.read(u16);
        var fields = std.ArrayList(JField).init(self.allocator());
        defer fields.deinit();

        for (range(fieldsCount)) |_, i| {
            try fields.append(JField{
                .flags = try reader.read(u16),
                .name = try self.resolveString(try reader.read(u16), jClass, reader),
                .desc = try self.resolveString(try reader.read(u16), jClass, reader),
                .attributes = try self.parseSubAttributes(jClass, reader)
            });
        }

        jClass.fields = fields.toOwnedSlice();
    }

    fn parseMethods(self: *Self,
                jClass: *JClass, reader: *Reader) !void {
        var methodsCount: u16 = try reader.read(u16);
        var methods = std.ArrayList(JMethod).init(self.allocator());
        methods.deinit();

        for (range(methodsCount)) |_, i| {
            try methods.append(JMethod{
                .flags = try reader.read(u16),
                .name = try self.resolveString(try reader.read(u16), jClass, reader),
                .desc = try self.resolveString(try reader.read(u16), jClass, reader),
                .attributes = try self.parseSubAttributes(jClass, reader)
            });
        }

        jClass.methods = methods.toOwnedSlice();
    }

    fn resolveString(self: *Self, index: u16,
                jClass: *JClass, reader: *Reader) ![]u8 {
        if ((index - 1) > jClass.constant_pool.len) {
            return error.JConstIndexOutOfBounds;
        }

        var jConst: JConst = jClass.constant_pool[index - 1];
        switch (jConst.tag) {
            .string => {
                var string: []u8 = try self.allocator().alloc(u8, jConst.string.len);
                errdefer self.allocator().free(string);

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