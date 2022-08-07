const std = @import("std");
const log = std.log;

const vmDef = @import("vm.zig");
const VM = vmDef.VM;

pub fn main() !void {
    var hpkt: VM = VM.init();
    try hpkt.load("/home/racemus/projects/hotpocket/jvm/jars/glushed-agent.jar");
}