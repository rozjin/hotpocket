const std = @import("std");
const fs = std.fs;
const io = std.io;
const log = std.log;
const mem = std.mem;

const jLoaderDef = @import("loader.zig");
const jClassDef = @import("class.zig");
const gcDef = @import("gc.zig");

const opDef = @import("op.zig");
const invokeDef = @import("invoke.zig");

const readerDef = @import("reader.zig");

const Op = opDef.Op;
const Invoke = invokeDef.Invoke;

const GC = gcDef.GC;
const GCContext = GC.Context;
const GCAllocator = GC.GPAllocator;

const JLoader = jLoaderDef.JLoader;
const JClass = jClassDef.JClass;

const JMethod = JClass.JMethod;
const JAttribute = JClass.JAttribute;
const JAttributeTag = JClass.JAttributeTag;

const JCode = JAttribute.JCode;
const JErrorFn = JCode.JErrorFn;

const Reader = readerDef.Reader;

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
        ref: u64,
    };

    const VMObject = struct {
        vars: []VMVar,
        
    };

    const VMFrame = struct {
        method: *JClass.JMethod = undefined,
        class: *JClass = undefined,
        ip: u32 = undefined,
        code: []u8 = undefined,
        locals: *GCContext = undefined,
        stack: *GCContext = undefined,

        locals_size: usize = undefined,
        stack_size: usize = undefined,

        errors: []JErrorFn = undefined,

        const Self = @This();

        fn init(self: *Self, 
                jClass: *JClass, jObject: ?*VMObject,
                jMethod: *JMethod,
                jArgs: []VMVar, jGC: GC) Self {
            if (jObject) ctx.push(@ptrToInt(jObject.?));
            for (jArgs) |jArg| {
                ctx.prod(jArg); 
            }

            var jCodeAttr: JAttribute = jMethod.find(JAttributeTag.Code);
            var jCode: JCode = jCodeAttr.jCode;
            return Self {
                .method = jMethod,
                .class = jClass,
                
                .ip = 0,
                
                .code = jCode.code,
                .locals = try jGC.make(),
                .stack = try jGC.make(),

                .locals_size = jCode.maxStack,
                .stack_size = jCode.maxLocals,

                .errors = jCode.exceptions
            }; 
        }
    };

    jClasses: []JClass = undefined,

    jFrames: []VMFrame = undefined,
    jFramesSize: u32 = undefined,
    jFramesMax: u32 = undefined,

    jFrameStackMax: u32 = undefined,

    jStackSize: u32 = undefined,
    jStackMax: u32 = undefined,

    jGC: GC = undefined,
    jGPA: GCAllocator = undefined,

    const Self = @This();
    const gcMaxObjects = 64;

    pub fn init(max_frames: u32, frame_size: u32) Self {
        var vmGC = GC.init(gcMaxObjects, frame_size);
        var vmGPA = vmGC.gpa;

        return Self {
            .jFramesSize = 0,
            .jFramesMax = max_frames,

            .jFrameStackMax = frame_size,

            .jStackSize = 0,
            .jStackMax = max_frames * frame_size,

            .jGC = vmGC,
            .jGPA = vmGPA
        };
    }

    pub fn load(self: *Self, class_path: []const u8) !void {
        log.info("[K] JVM Start.", .{});

        var loader: JLoader = JLoader.init();
        var jar_files = [_][]const u8 { class_path };
        self.jClasses = try loader.loadJars(&jar_files);
        log.info("[K] Loaded Jars.", .{});

        log.info("[K] Done.", .{});
    }

    fn invoke(self: *Self, kind: Invoke, 
              jClass: *JClass, jObject: ?*VMObject,
              jMethod: *JMethod,
              jArgs: []VMVar) !VMFrame {
        var jMem = self.jGPA.allocator();
        var jFrame: *VMFrame = try jMem.create(VMFrame);
        jFrame.init(jClass, jObject, jMethod, jArgs, self.jGC);

        switch (kind) {
            .STATIC => {
                self.jit(jClass, jObject)
            },

            else => log.warn("[K] Unsupported Method Kind", .{})
        }
    }

    fn jit(self: *Self,
           jClass: *JClass, jObject: ?*VMObject)
};