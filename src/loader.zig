const std = @import("std");
const fs = std.fs;
const io = std.io;
const log = std.log;

const reader = @import("reader.zig");
const class = @import("class.zig");

const Reader = reader.Reader;

const JClass = class.JClass;
const JConst = JClass.JConst;
const JConstTag = JClass.JConstTag;

const JClassLoader = struct {
    jClassAllocator:  *std.mem.Allocator = undefined,

    const Self = @This();
    const JMagic = 0xCAFEBABE;

    pub fn init(buf: []u8) Self {
        return Self {
            .jClassAllocator = &std.heap.ArenaAllocator
                .init(std.heap.page_allocator)
                .allocator
        };
    }

    pub fn parseClass(self: *Self, buf: []u8) !JClass {
        var reader = Reader.init(buf);

        var magic: u32 = try reader.read(u32);
        if (magic != JMagic) {
            log.err("[P] Bad magic number {x}", .{magic});
            return error.JBadMagicNumber;
        }

        var jClass = try self.jClassAllocator.create(JClass);
        errdefer self.jClassAllocator.destroy(jClass);

        try self.parseMagic(jClass, reader);
        try self.parseConstants(jClass, reader);
        try self.parseMeta(jClass);
        try self.parseInterfaces(jClass);

        try self.parseFields(jClass);
        try self.parseMethods(jClass);

        try self.parseAttributes();

        return jClass;
    }

    pub fn parseMagic(self: *Self, 
                jClass: *JClass, reader: Reader) !void {
        jClass.magic = JMagic;
        jClass.minor = try reader.read(u16);
        jClass.major = try reader.read(u16);
    }

    pub fn parseConstants(self: *Self,
                jClass: *JClass, reader: Reader) !void {
        var constant_pool = std.ArrayList(JConst).init(self.jClassAllocator);
        var constCount: u16 = try reader.read(u16);

        defer constant_pool.deinit();

        var i: usize = 1;
        while (i < constCount) : (i = i + 1) {
            var jConst: JConst = JConst{ .tag = @intToEnum(JConstTag, try reader.read(u8)) };
            switch (jConst.tag) {
                .class => {
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
                    var stringLen = try reader.read(u16);
                    jConst.string = try reader.readBytes(stringLen);
                },

                else => {
                    log.err("[P] Unsupported Tag: {}", .{jConst.tag});
                    return error.JConstUnsupportedTag;
                }
            }

            try constant_pool.append(jConst);
            if (jConst.tag == JConstTag.double or jConst.tag == JConstTag.long) {
                try constant_pool.append(JConst{ .tag = JConstTag.integer });
                i = i + 1;
            }
        }

        jClass.constant_pool =  constant_pool.toOwnedSlice();
    }

    pub fn parseMeta(self: *Self) !void {
        self.flags = try self.reader.read(u16);

        self.name = try self.resolveString(try self.reader.read(u16));
        self.super = try self.resolveString(try self.reader.read(u16));
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
};