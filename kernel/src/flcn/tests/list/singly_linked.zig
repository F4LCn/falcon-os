const std = @import("std");
const SinglyLinkedList = @import("../../list.zig").SinglyLinkedList;

const TestType = struct {
    const Self = @This();
    next: ?*Self = null,
    value: u32,
};

const TestTypeList = SinglyLinkedList(TestType, .next);

test "list should init" {
    const list = TestTypeList{};

    try std.testing.expectEqual(null, list.head);
    try std.testing.expectEqual(0, list.len());
}

test "prepend should increase length" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    var node2 = TestType{ .value = 321 };
    list.prepend(&node1);
    list.prepend(&node2);

    try std.testing.expectEqual(&node2, list.head);
    try std.testing.expectEqual(&node1, @field(list.head.?, "next"));
    try std.testing.expectEqual(2, list.len());
}

test "popFirst should decrease length" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    var node2 = TestType{ .value = 321 };
    list.prepend(&node1);
    list.prepend(&node2);

    const popped_node1 = list.popFirst();

    try std.testing.expectEqual(&node2, popped_node1);
    try std.testing.expectEqual(1, list.len());

    const popped_node2 = list.popFirst();

    try std.testing.expectEqual(&node1, popped_node2);
    try std.testing.expectEqual(0, list.len());
}

test "removing head results in empty list" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    list.prepend(&node1);

    list.remove(&node1);

    try std.testing.expectEqual(null, list.head);
    try std.testing.expectEqual(0, list.len());
}

test "removing node should decrease length" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    var node2 = TestType{ .value = 321 };
    var node3 = TestType{ .value = 456 };
    list.prepend(&node1);
    list.prepend(&node2);

    list.remove(&node2);

    try std.testing.expectEqual(&node1, list.head);
    try std.testing.expectEqual(1, list.len());

    list.remove(&node2);

    try std.testing.expectEqual(&node1, list.head);
    try std.testing.expectEqual(1, list.len());

    list.prepend(&node3);

    list.remove(&node1);

    try std.testing.expectEqual(&node3, list.head);
    try std.testing.expectEqual(1, list.len());
}
