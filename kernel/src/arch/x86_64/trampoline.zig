pub const trampoline_data = @embedFile("trampoline");

pub const TrampolineParams = extern struct {
    entrypoint:  u64 align(1),
    page_map: u32 align(1),
    status: u16 align(1) = undefined,
};
