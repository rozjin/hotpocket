pub const Reader = struct {
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