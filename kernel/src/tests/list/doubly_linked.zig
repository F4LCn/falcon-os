const std = @import("std");
const DoublyLinkedList = @import("../../list.zig").DoublyLinkedList;

const TestType = struct {
    const Self = @This();
    prev: ?*Self = null,
    next: ?*Self = null,
    value: u32,
};

const TestTypeList = DoublyLinkedList(TestType, .prev, .next);

test "list should init" {
    const list = TestTypeList{};

    try std.testing.expectEqual(null, list.head);
    try std.testing.expectEqual(null, list.tail);
}

test "prepend should correctly set next and prev" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    var node2 = TestType{ .value = 321 };
    list.prepend(&node1);
    list.prepend(&node2);

    try std.testing.expectEqual(&node2, list.head);
    try std.testing.expectEqual(&node1, list.tail);
    try std.testing.expectEqual(&node1, @field(list.head.?, "next"));
    try std.testing.expectEqual(null, @field(list.head.?, "prev"));
    try std.testing.expectEqual(&node2, @field(list.tail.?, "prev"));
    try std.testing.expectEqual(null, @field(list.tail.?, "next"));
}

test "append should correctly set next and prev" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    var node2 = TestType{ .value = 321 };
    list.append(&node1);
    list.append(&node2);

    try std.testing.expectEqual(&node1, list.head);
    try std.testing.expectEqual(&node2, list.tail);
    try std.testing.expectEqual(&node2, @field(list.head.?, "next"));
    try std.testing.expectEqual(null, @field(list.head.?, "prev"));
    try std.testing.expectEqual(&node1, @field(list.tail.?, "prev"));
    try std.testing.expectEqual(null, @field(list.tail.?, "next"));
}

test "popFirst should return the first element" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    var node2 = TestType{ .value = 321 };
    list.append(&node1);
    list.prepend(&node2);

    const popped_node1 = list.popFirst();

    try std.testing.expectEqual(&node2, popped_node1);
    try std.testing.expectEqual(null, @field(popped_node1.?, "prev"));
    try std.testing.expectEqual(null, @field(popped_node1.?, "next"));

    const popped_node2 = list.popFirst();

    try std.testing.expectEqual(&node1, popped_node2);
    try std.testing.expectEqual(null, @field(popped_node2.?, "prev"));
    try std.testing.expectEqual(null, @field(popped_node2.?, "next"));

    try std.testing.expectEqual(null, list.head);
    try std.testing.expectEqual(null, list.tail);
}

test "pop should return the last element" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    var node2 = TestType{ .value = 321 };
    list.append(&node1);
    list.append(&node2);

    const popped_node1 = list.pop();

    try std.testing.expectEqual(&node2, popped_node1);
    try std.testing.expectEqual(null, @field(popped_node1.?, "prev"));
    try std.testing.expectEqual(null, @field(popped_node1.?, "next"));

    const popped_node2 = list.pop();

    try std.testing.expectEqual(&node1, popped_node2);
    try std.testing.expectEqual(null, @field(popped_node2.?, "prev"));
    try std.testing.expectEqual(null, @field(popped_node2.?, "next"));

    try std.testing.expectEqual(null, list.head);
    try std.testing.expectEqual(null, list.tail);
}

test "insertBefore" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    var node2 = TestType{ .value = 321 };
    var node3 = TestType{ .value = 456 };
    var node4 = TestType{ .value = 654 };
    list.append(&node1);
    list.append(&node2);

    list.insertBefore(&node2, &node3);

    try std.testing.expectEqual(&node2, @field(node3, "next"));
    try std.testing.expectEqual(&node3, @field(node2, "prev"));

    list.insertBefore(&node1, &node4);
    try std.testing.expectEqual(&node1, @field(node4, "next"));
    try std.testing.expectEqual(&node4, @field(node1, "prev"));

    try std.testing.expectEqual(&node4, list.head);
}

test "insertAfter" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    var node2 = TestType{ .value = 321 };
    var node3 = TestType{ .value = 456 };
    var node4 = TestType{ .value = 654 };
    list.append(&node1);
    list.append(&node2);

    list.insertAfter(&node2, &node3);

    try std.testing.expectEqual(&node2, @field(node3, "prev"));
    try std.testing.expectEqual(&node3, @field(node2, "next"));

    list.insertAfter(&node3, &node4);
    try std.testing.expectEqual(&node3, @field(node4, "prev"));
    try std.testing.expectEqual(&node4, @field(node3, "next"));

    try std.testing.expectEqual(&node4, list.tail);
}

test "concat with empty list" {
    var list1 = TestTypeList{};
    var list2 = TestTypeList{};
    var node3 = TestType{ .value = 456 };
    var node4 = TestType{ .value = 654 };
    list2.append(&node3);
    list2.append(&node4);

    list1.concat(&list2);

    try std.testing.expectEqual(&node3, list1.head);
    try std.testing.expectEqual(&node4, list1.tail);
    try std.testing.expectEqual(null, @field(node4, "next"));
    try std.testing.expectEqual(null, @field(node3, "prev"));
}

test "concat" {
    var list1 = TestTypeList{};
    var list2 = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    var node2 = TestType{ .value = 321 };
    var node3 = TestType{ .value = 456 };
    var node4 = TestType{ .value = 654 };
    list1.append(&node1);
    list1.append(&node2);
    list2.append(&node3);
    list2.append(&node4);

    list1.concat(&list2);

    try std.testing.expectEqual(&node1, list1.head);
    try std.testing.expectEqual(&node4, list1.tail);
    try std.testing.expectEqual(&node3, @field(node2, "next"));
    try std.testing.expectEqual(&node2, @field(node3, "prev"));
}

test "removing head results in empty list" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    list.prepend(&node1);

    list.remove(&node1);

    try std.testing.expectEqual(null, list.head);
    try std.testing.expectEqual(null, list.tail);
}

test "removing node" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    var node2 = TestType{ .value = 321 };
    var node3 = TestType{ .value = 456 };
    var node4 = TestType{ .value = 654 };
    list.prepend(&node1);
    list.prepend(&node2);

    list.remove(&node2);

    try std.testing.expectEqual(&node1, list.head);
    try std.testing.expectEqual(&node1, list.tail);

    list.remove(&node2);

    try std.testing.expectEqual(&node1, list.head);
    try std.testing.expectEqual(&node1, list.tail);

    list.append(&node3);
    list.prepend(&node4);

    list.remove(&node1);

    try std.testing.expectEqual(&node4, list.head);
    try std.testing.expectEqual(&node3, list.tail);
    try std.testing.expectEqual(&node3, @field(node4, "next"));
    try std.testing.expectEqual(&node4, @field(node3, "prev"));
}

test "iter" {
    var list = TestTypeList{};
    var node1 = TestType{ .value = 123 };
    var node2 = TestType{ .value = 321 };
    var node3 = TestType{ .value = 456 };
    var node4 = TestType{ .value = 654 };
    list.append(&node1);
    list.append(&node2);
    list.append(&node3);
    list.append(&node4);

    var iter = list.iter();

    const first_node = iter.next();
    try std.testing.expectEqual(&node1, first_node.?);
    const second_node = iter.next();
    try std.testing.expectEqual(&node2, second_node.?);
    const third_node = iter.next();
    try std.testing.expectEqual(&node3, third_node.?);
    const fourth_node = iter.next();
    try std.testing.expectEqual(&node4, fourth_node.?);
    const null_node = iter.next();
    try std.testing.expectEqual(null, null_node);
}
