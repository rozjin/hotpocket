const std = @import("std");
const log = std.log;

const vmDef = @import("vm.zig");
const VM = vmDef.VM;

pub fn main() !void {
    var hpkt: VM = VM.init(128, 256);
    try hpkt.load("jars/rt.jar");
}