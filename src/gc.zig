const std = @import("std");
const mem = std.mem;
const heap = std.heap;

const List = std.ArrayList;

pub const GC = struct {
    pub const GCRef = struct {
        gc: *GC = undefined,
        ptr: u64 = undefined,
        par: u64 = undefined
    };
    
    gpa: heap.GeneralPurposeAllocator = undefined,
    mem: *mem.Allocator = undefined,
    objs: List(u64) = undefined,

    const Self = @This();

    pub fn init() Self {
        var gpa = heap.GeneralPurposeAllocator(.{}){};
        var mem = &gpa.allocator;

        return Self {
            .gpa = gpa,
            .mem = mem,
            .objs = List(u64).init(mem)
        };
    }

    pub fn make(self: *Self, size: usize, par: usize) !GCRef {
        var bytes: []u8 = self.mem.alloc(u8, usize);
        var ptr: u64 = @ptrToInt(bytes.ptr);
        self.objs.append(ptr);

        return .{
            .gc = self,
            .ptr = ptr,
            .par = par
        };
    }

    pub fn mark(self: *Self) void {
        
    }

    pub fn sweep() void {

    }
};