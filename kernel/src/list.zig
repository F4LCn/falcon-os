const std = @import("std");

pub fn SinglyLinkedList(comptime T: anytype, comptime next_field: std.meta.FieldEnum(T)) type {
    return struct {
        const Self = @This();
        const next = std.meta.fieldInfo(T, next_field).name;

        head: ?*T = null,

        pub fn prepend(self: *Self, new_node: *T) void {
            if (self.head) |_| {
                @field(new_node, next) = self.head;
            }

            self.head = new_node;
        }

        pub fn len(self: Self) usize {
            if (self.head == null) {
                return 0;
            }
            var cursor = self.head;
            var length: usize = 0;
            while (cursor) |c| {
                defer cursor = @field(c, next);
                length += 1;
            }
            return length;
        }

        pub fn popFirst(self: *Self) ?*T {
            const popped_item = self.head;

            if (self.head) |h| {
                self.head = @field(h, next);
            }

            if (popped_item) |pi| {
                @field(pi, next) = null;
            }

            return popped_item;
        }

        pub fn remove(self: *Self, node: *T) void {
            if (self.head == node) {
                if (self.head) |h| {
                    self.head = @field(h, next);
                }
                return;
            }

            var cursor = self.head;
            while (cursor) |c| {
                const cursor_next = @field(c, next);
                defer cursor = cursor_next;
                if (cursor_next == node) {
                    @field(c, next) = @field(node, next);
                }
            }
        }
    };
}

pub fn DoublyLinkedList(comptime T: anytype, prev_field: std.meta.FieldEnum(T), next_field: std.meta.FieldEnum(T)) type {
    return struct {
        const Self = @This();
        const prev = std.meta.fieldInfo(T, prev_field).name;
        const next = std.meta.fieldInfo(T, next_field).name;

        head: ?*T = null,
        tail: ?*T = null,

        pub fn prepend(self: *Self, new_node: *T) void {
            if (self.head) |h| {
                @field(new_node, next) = h;
                @field(h, prev) = new_node;
                self.head = new_node;
                return;
            }
            self.head = new_node;
            self.tail = new_node;
        }
        pub fn append(self: *Self, new_node: *T) void {
            if (self.tail) |t| {
                @field(new_node, prev) = t;
                @field(t, next) = new_node;
                self.tail = new_node;
                return;
            }
            self.head = new_node;
            self.tail = new_node;
        }
        pub fn popFirst(self: *Self) ?*T {
            const popped_item = self.head;
            if (self.head) |old_head| {
                self.head = @field(old_head, next);
                if (self.head) |new_head| {
                    @field(new_head, prev) = null;
                } else {
                    self.tail = null;
                }
            }

            if (popped_item) |pi| {
                @field(pi, prev) = null;
                @field(pi, next) = null;
            }

            return popped_item;
        }

        pub fn pop(self: *Self) ?*T {
            const popped_item = self.tail;
            if (self.tail) |old_tail| {
                self.tail = @field(old_tail, prev);
                if (self.tail) |new_tail| {
                    @field(new_tail, next) = null;
                } else {
                    self.head = null;
                }
            }

            if (popped_item) |pi| {
                @field(pi, prev) = null;
                @field(pi, next) = null;
            }

            return popped_item;
        }

        pub fn insertBefore(self: *Self, node: *T, new_node: *T) void {
            std.debug.assert(self.head != null and self.tail != null);
            const node_prev = @field(node, prev);
            if (node_prev) |np| {
                @field(np, next) = new_node;
            } else {
                self.head = new_node;
            }
            @field(new_node, prev) = node_prev;

            @field(new_node, next) = node;
            @field(node, prev) = new_node;
        }

        pub fn insertAfter(self: *Self, node: *T, new_node: *T) void {
            std.debug.assert(self.head != null and self.tail != null);
            const node_next = @field(node, next);
            if (node_next) |nx| {
                @field(nx, prev) = new_node;
            } else {
                self.tail = new_node;
            }
            @field(new_node, next) = node_next;

            @field(new_node, prev) = node;
            @field(node, next) = new_node;
        }

        pub fn concat(self: *Self, other: *const Self) void {
            if (self.tail) |t| {
                @field(t, next) = other.head;
            } else {
                self.head = other.head;
            }

            if (other.head) |oh| {
                @field(oh, prev) = self.tail;
            }

            self.tail = other.tail;
        }

        pub fn remove(self: *Self, node: *T) void {
            if (self.head == node) {
                if (self.head) |h| {
                    self.head = @field(h, next);
                    if (self.head) |new_head| {
                        @field(new_head, prev) = null;
                    } else {
                        self.tail = null;
                    }
                }
                return;
            }

            const node_prev = @field(node, prev);
            const node_next = @field(node, next);

            if (node_prev) |p| {
                @field(p, next) = node_next;
            }
            if (node_next) |n| {
                @field(n, prev) = node_prev;
            }
        }
    };
}

test {
    _ = @import("tests/list/singly_linked.zig");
    _ = @import("tests/list/doubly_linked.zig");
}
