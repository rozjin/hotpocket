const std = @import("std");
const log = std.log;

const vm = @import("vm.zig");

pub fn main() !void {
    var hpkt: vm.VM = .{};
    try hpkt.init("test/Add.class");
}