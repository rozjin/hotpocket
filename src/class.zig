const std = @import("std");
const fs = std.fs;
const io = std.io;
const log = std.log;

pub const JClass = struct {
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

    constant_pool: []JConst = undefined,
    interfaces: [][]u8 = undefined,
    fields: []JField = undefined,
    methods: []JMethod = undefined,
    attributes: []JAttribute = undefined,

    flags: u16 = undefined,
    name: []u8 = undefined,
    super: []u8 = undefined,

    magic: u32 = undefined,
    minor: u16 = undefined,
    major: u16 = undefined,

    const Self = @This();
    
    pub fn info(self: *Self) !void {
        log.info("[K] Name => {s}", .{self.name});
        log.info("[K] Super => {s}", .{self.super});
        log.info("[K] Flags => 0x{x}", .{self.flags});

        log.info("[K] CP Size => {}", .{self.constant_pool.len});
        for (self.constant_pool) |jConst| {
            log.info("[K] CP Item Tag: 0x{x}", .{@enumToInt(jConst.tag)});
        }

        log.info("[K] IF Size => {}", .{self.interfaces.len});
        log.info("[K] FL Size => {}", .{self.fields.len});
        log.info("[K] MT Size => {}", .{self.methods.len});
        for (self.methods) |jMethod| {
           log.info("[K] MT Attributes :=> {} items", .{jMethod.attributes.len});
           for (jMethod.attributes) |jMethodAttribute| {
                log.info("[K] MT Attribute: {s}", .{@tagName(jMethodAttribute.tag)});
            }
        }

        log.info("[K] AT Size => {}", .{self.attributes.len});
    }
};