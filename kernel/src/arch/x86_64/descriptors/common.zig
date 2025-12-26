const Segment = @import("types.zig").Segment;

pub const kernel_code_segment_selector: Segment.Selector = .{ .index = 1 };
pub const kernel_data_segment_selector: Segment.Selector = .{ .index = 2 };
