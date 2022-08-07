const std = @import("std");
const fs = std.fs;
const io = std.io;
const log = std.log;

const jLoaderDef = @import("loader.zig");
const jClassDef = @import("class.zig");
const gcDef = @import("gc.zig");

const GC = gcDef.GC;
const GCRef = GC.GCRef;

const JLoader = jLoaderDef.JLoader;
const JClass = jClassDef.JClass;

pub const VM = struct {
    const VMNull: u64 = 0xAA;
    const VMError = error {
        Internal,
        OutOfMemory,
        StackOverflow,
        Unknown
    };
    
    const VMVar = union(enum) {
        byte: i8,
        short: i16,
        int: i32,
        long: i64,
        float: f32,
        double: f64,
        boolean: bool,
        ref: ?GCRef,
    };

    const VMObject = struct {
        ref: GCRef,
        fields: []VMVar
    };

    const VMFrame = struct {
        method: *JClass.JMethod,
        class: *JClass,
        ip: u32,
        code: []u8,
        locals: []VMVar,
        stack: []VMVar,
        stackTop: usize,
        obj: ?GCRef
    };

    jClasses: []JClass,
    jObjects: []VMObject,

    const Self = @This();

    pub fn init() Self {
        return Self {};
    }

    pub fn initObjects(self: *Self) !void {

    }

    pub fn load(self: *Self, class_path: []const u8) !void {
        log.info("[K] JVM Start", .{});
        var loader: JLoader = JLoader.init();
        var jar_files = [_][]const u8 { class_path };

        self.jClasses = try loader.loadJars(&jar_files);
        self.jObjects = try self.initObjects();
    }
};