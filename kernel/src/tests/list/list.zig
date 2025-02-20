const std = @import("std");
const List = @import("../../list.zig").List;
const ListLink = @import("../../list.zig").ListLink;

const TestType = struct {
    val1: u32 = 234,
    val2: u32 = 65645,
    val3: bool = false,
    link: ListLink = .create(),
};

test "use link in list and retrieve parent type" {
    var list = List{};
    var item1 = TestType{};

    std.debug.print("{any}", .{item1});
    list.append(&item1.link);

    const popped_item1 = list.pop();
    try std.testing.expectEqual(&item1.link, popped_item1.?);
    const parent1: *TestType = @fieldParentPtr("link", popped_item1.?);
    try std.testing.expectEqual(&item1, parent1);
}
