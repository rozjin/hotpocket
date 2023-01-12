const std = @import("std");

const mem = std.mem;
const log = std.log;

pub const Reader = struct {
    buf: []u8 = undefined,
    len: usize = undefined,
    pos: usize = undefined,
    pos_eof: usize = undefined,

    const Self = @This();

    pub fn init(buf: []u8) Self {
        return Self {
            .buf = buf,
            .len = buf.len,
            .pos = 0,
            .pos_eof = buf.len,
        };
    }

    pub fn read(self: *Self, comptime T: type) !T {
        var begin: usize = self.pos;
        var end: usize = self.pos + @sizeOf(T);

        if (begin > self.len or end > self.len) {
            return error.Overflow;
        }

        var val: T = switch(@typeInfo(T)) {
            .Int => @byteSwap(@ptrCast(*align(1) T, self.buf[begin..end]).*),
            else => @ptrCast(*align(1) T, self.buf[begin..end]).*
        };

        self.pos = self.pos + @sizeOf(T);

        return val;
    }

    pub fn readEOF(self: *Self, comptime T: type) !T {
        var begin: usize = self.pos_eof - @sizeOf(T);
        var end: usize = self.pos_eof;

        if (begin <= 0) {
            return error.Underflow;
        }

        self.pos_eof = self.pos_eof - @sizeOf(T);

        return switch(@typeInfo(T)) {
            .Int => @byteSwap(@ptrCast(*align(1) T, self.buf[begin..end]).*),
            else => @ptrCast(*align(1) T, self.buf[begin..end]).*
        };
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

    pub fn readBytesPos(self: *Self, pos: usize, read_len: usize) ![]u8 {
        if (pos > self.len or pos < 0) {
            return error.InvalidPos;
        }

        self.pos = pos;

        var begin: usize = self.pos;
        var end: usize = self.pos + read_len;

        if (begin > self.len or end > self.len) {
            return error.Overflow;
        }

        var slice: []u8 = self.buf[begin..end];
        return slice;     
    }

    pub fn readPos(self: *Self, pos: usize, comptime T: type) !T {
        if (pos > self.len or pos < 0) {
            return error.InvalidPos;
        }

        self.pos = pos;

        var begin: usize = self.pos;
        var end: usize = self.pos + @sizeOf(T);

        if (begin > self.len or end > self.len) {
            return error.Overflow;
        }

        var val: T = switch(@typeInfo(T)) {
            .Int => @byteSwap(@ptrCast(*align(1) T, self.buf[begin..end]).*),
            else => @ptrCast(*align(1) T, self.buf[begin..end]).*
        };

        return val; 
    }

    pub fn readLeft(self: *Self) ![]u8 {
        return self.buf[self.pos..];
    }
};