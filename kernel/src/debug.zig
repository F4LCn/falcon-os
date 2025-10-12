const debug = @import("flcn").debug;
const arch = @import("arch");

pub const SelfInfo = debug.SelfInfo;
pub const CpuContext = arch.cpu.CpuContext;
pub const Stacktrace = debug.Stacktrace;
pub const init = debug.init;
pub const getDebugInfoAllocator = debug.getDebugInfoAllocator;
