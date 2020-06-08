// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const View = @import("View.zig");

/// A specialized doubly-linked stack that allows for filtered iteration
/// over the nodes. T must be View or *View.
pub fn ViewStack(comptime T: type) type {
    if (!(T == View or T == *View)) {
        @compileError("ViewStack: T must be View or *View");
    }
    return struct {
        const Self = @This();

        pub const Node = struct {
            /// Previous/next nodes in the stack
            prev: ?*Node,
            next: ?*Node,

            /// The view stored in this node
            view: T,
        };

        /// Top/bottom nodes in the stack
        first: ?*Node,
        last: ?*Node,

        /// Initialize an undefined stack
        pub fn init(self: *Self) void {
            self.first = null;
            self.last = null;
        }

        /// Add a node to the top of the stack.
        pub fn push(self: *Self, new_node: *Node) void {
            // Set the prev/next pointers of the new node
            new_node.prev = null;
            new_node.next = self.first;

            if (self.first) |first| {
                // If the list is not empty, set the prev pointer of the current
                // first node to the new node.
                first.prev = new_node;
            } else {
                // If the list is empty set the last pointer to the new node.
                self.last = new_node;
            }

            // Set the first pointer to the new node
            self.first = new_node;
        }

        /// Swap positions of two nodes in the view stack.
        pub fn swap(self: *Self, node_x: *Node, node_y: *Node) void {
            if (node_x == node_y) return;

            // Swap next pointers of the two nodes.
            const temp_next = node_x.next;
            node_x.next = node_y.next;
            node_y.next = temp_next;

            // Update view stack.
            if (node_x.next) |next_node| {
                next_node.prev = node_x;
            } else {
                self.last = node_x;
            }
            if (node_y.next) |next_node| {
                next_node.prev = node_y;
            } else {
                self.last = node_y;
            }

            // Swap prev pointers of the two nodes.
            const temp_prev = node_x.prev;
            node_x.prev = node_y.prev;
            node_y.prev = temp_prev;

            // Update view stack.
            if (node_x.prev) |prev_node| {
                prev_node.next = node_x;
            } else {
                self.first = node_x;
            }
            if (node_y.prev) |prev_node| {
                prev_node.next = node_y;
            } else {
                self.first = node_y;
            }
        }

        /// Remove a node from the view stack. This removes it from the stack of
        /// all views as well as the stack of visible ones.
        pub fn remove(self: *Self, target_node: *Node) void {
            // Set the previous node/list head to the next pointer
            if (target_node.prev) |prev_node| {
                prev_node.next = target_node.next;
            } else {
                self.first = target_node.next;
            }

            // Set the next node/list tail to the previous pointer
            if (target_node.next) |next_node| {
                next_node.prev = target_node.prev;
            } else {
                self.last = target_node.prev;
            }
        }

        const Iterator = struct {
            it: ?*Node,
            tags: u32,
            reverse: bool,
            pending: bool,

            /// Returns the next node in iteration order, or null if done.
            /// This function is horribly ugly, but it's well tested below.
            pub fn next(self: *Iterator) ?*Node {
                while (self.it) |node| : (self.it = if (self.reverse) node.prev else node.next) {
                    if (if (self.pending)
                        if (node.view.pending_tags) |pending_tags|
                            self.tags & pending_tags != 0
                        else
                            self.tags & node.view.current_tags != 0
                    else
                        self.tags & node.view.current_tags != 0) {
                        self.it = if (self.reverse) node.prev else node.next;
                        return node;
                    }
                }
                return null;
            }
        };

        /// Returns an iterator starting at the passed node and filtered by
        /// checking the passed tags against the current tags of each view.
        pub fn iterator(start: ?*Node, tags: u32) Iterator {
            return Iterator{
                .it = start,
                .tags = tags,
                .reverse = false,
                .pending = false,
            };
        }

        /// Returns a reverse iterator starting at the passed node and filtered by
        /// checking the passed tags against the current tags of each view.
        pub fn reverseIterator(start: ?*Node, tags: u32) Iterator {
            return Iterator{
                .it = start,
                .tags = tags,
                .reverse = true,
                .pending = false,
            };
        }

        /// Returns an iterator starting at the passed node and filtered by
        /// checking the passed tags against the pending tags of each view.
        /// If a view has no pending tags, the current tags are used.
        pub fn pendingIterator(start: ?*Node, tags: u32) Iterator {
            return Iterator{
                .it = start,
                .tags = tags,
                .reverse = false,
                .pending = true,
            };
        }
    };
}

test "push/remove (*View)" {
    const testing = @import("std").testing;

    const allocator = testing.allocator;

    var views: ViewStack(*View) = undefined;
    views.init();

    const one = try allocator.create(ViewStack(*View).Node);
    defer allocator.destroy(one);
    const two = try allocator.create(ViewStack(*View).Node);
    defer allocator.destroy(two);
    const three = try allocator.create(ViewStack(*View).Node);
    defer allocator.destroy(three);
    const four = try allocator.create(ViewStack(*View).Node);
    defer allocator.destroy(four);
    const five = try allocator.create(ViewStack(*View).Node);
    defer allocator.destroy(five);

    views.push(three); // {3}
    views.push(one); // {1, 3}
    views.push(four); // {4, 1, 3}
    views.push(five); // {5, 4, 1, 3}
    views.push(two); // {2, 5, 4, 1, 3}

    // Simple insertion
    {
        var it = views.first;
        testing.expect(it == two);
        it = it.?.next;
        testing.expect(it == five);
        it = it.?.next;
        testing.expect(it == four);
        it = it.?.next;
        testing.expect(it == one);
        it = it.?.next;
        testing.expect(it == three);
        it = it.?.next;

        testing.expect(it == null);

        testing.expect(views.first == two);
        testing.expect(views.last == three);
    }

    // Removal of first
    views.remove(two);
    {
        var it = views.first;
        testing.expect(it == five);
        it = it.?.next;
        testing.expect(it == four);
        it = it.?.next;
        testing.expect(it == one);
        it = it.?.next;
        testing.expect(it == three);
        it = it.?.next;

        testing.expect(it == null);

        testing.expect(views.first == five);
        testing.expect(views.last == three);
    }

    // Removal of last
    views.remove(three);
    {
        var it = views.first;
        testing.expect(it == five);
        it = it.?.next;
        testing.expect(it == four);
        it = it.?.next;
        testing.expect(it == one);
        it = it.?.next;

        testing.expect(it == null);

        testing.expect(views.first == five);
        testing.expect(views.last == one);
    }

    // Remove from middle
    views.remove(four);
    {
        var it = views.first;
        testing.expect(it == five);
        it = it.?.next;
        testing.expect(it == one);
        it = it.?.next;

        testing.expect(it == null);

        testing.expect(views.first == five);
        testing.expect(views.last == one);
    }

    // Reinsertion
    views.push(two);
    views.push(three);
    views.push(four);
    {
        var it = views.first;
        testing.expect(it == four);
        it = it.?.next;
        testing.expect(it == three);
        it = it.?.next;
        testing.expect(it == two);
        it = it.?.next;
        testing.expect(it == five);
        it = it.?.next;
        testing.expect(it == one);
        it = it.?.next;

        testing.expect(it == null);

        testing.expect(views.first == four);
        testing.expect(views.last == one);
    }

    // Clear
    views.remove(four);
    views.remove(two);
    views.remove(three);
    views.remove(one);
    views.remove(five);

    testing.expect(views.first == null);
    testing.expect(views.last == null);
}

test "iteration (View)" {
    const c = @import("c.zig");
    const std = @import("std");
    const testing = std.testing;

    const allocator = testing.allocator;

    var views: ViewStack(View) = undefined;
    views.init();

    const one_a_pb = try allocator.create(ViewStack(View).Node);
    defer allocator.destroy(one_a_pb);
    one_a_pb.view.current_tags = 1 << 0;
    one_a_pb.view.pending_tags = 1 << 1;

    const two_a = try allocator.create(ViewStack(View).Node);
    defer allocator.destroy(two_a);
    two_a.view.current_tags = 1 << 0;
    two_a.view.pending_tags = null;

    const three_b_pa = try allocator.create(ViewStack(View).Node);
    defer allocator.destroy(three_b_pa);
    three_b_pa.view.current_tags = 1 << 1;
    three_b_pa.view.pending_tags = 1 << 0;

    const four_b = try allocator.create(ViewStack(View).Node);
    defer allocator.destroy(four_b);
    four_b.view.current_tags = 1 << 1;
    four_b.view.pending_tags = null;

    const five_b = try allocator.create(ViewStack(View).Node);
    defer allocator.destroy(five_b);
    five_b.view.current_tags = 1 << 1;
    five_b.view.pending_tags = null;

    views.push(three_b_pa); // {3}
    views.push(one_a_pb); // {1, 3}
    views.push(four_b); // {4, 1, 3}
    views.push(five_b); // {5, 4, 1, 3}
    views.push(two_a); // {2, 5, 4, 1, 3}

    // Iteration over all tags
    {
        var it = ViewStack(View).iterator(views.first, std.math.maxInt(u32));
        testing.expect((if (it.next()) |node| &node.view else null) == &two_a.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &five_b.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &four_b.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &one_a_pb.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &three_b_pa.view);
        testing.expect(it.next() == null);
    }

    // Iteration over 'a' tags
    {
        var it = ViewStack(View).iterator(views.first, 1 << 0);
        testing.expect((if (it.next()) |node| &node.view else null) == &two_a.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &one_a_pb.view);
        testing.expect(it.next() == null);
    }

    // Iteration over 'b' tags
    {
        var it = ViewStack(View).iterator(views.first, 1 << 1);
        testing.expect((if (it.next()) |node| &node.view else null) == &five_b.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &four_b.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &three_b_pa.view);
        testing.expect(it.next() == null);
    }

    // Iteration over tags that aren't present
    {
        var it = ViewStack(View).iterator(views.first, 1 << 2);
        testing.expect(it.next() == null);
    }

    // Reverse iteration over all tags
    {
        var it = ViewStack(View).reverseIterator(views.last, std.math.maxInt(u32));
        testing.expect((if (it.next()) |node| &node.view else null) == &three_b_pa.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &one_a_pb.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &four_b.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &five_b.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &two_a.view);
        testing.expect(it.next() == null);
    }

    // Reverse iteration over 'a' tags
    {
        var it = ViewStack(View).reverseIterator(views.last, 1 << 0);
        testing.expect((if (it.next()) |node| &node.view else null) == &one_a_pb.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &two_a.view);
        testing.expect(it.next() == null);
    }

    // Reverse iteration over 'b' tags
    {
        var it = ViewStack(View).reverseIterator(views.last, 1 << 1);
        testing.expect((if (it.next()) |node| &node.view else null) == &three_b_pa.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &four_b.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &five_b.view);
        testing.expect(it.next() == null);
    }

    // Reverse iteration over tags that aren't present
    {
        var it = ViewStack(View).reverseIterator(views.first, 1 << 2);
        testing.expect(it.next() == null);
    }

    // Iteration over (pending) 'a' tags
    {
        var it = ViewStack(View).pendingIterator(views.first, 1 << 0);
        testing.expect((if (it.next()) |node| &node.view else null) == &two_a.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &three_b_pa.view);
        testing.expect(it.next() == null);
    }

    // Iteration over (pending) 'b' tags
    {
        var it = ViewStack(View).pendingIterator(views.first, 1 << 1);
        testing.expect((if (it.next()) |node| &node.view else null) == &five_b.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &four_b.view);
        testing.expect((if (it.next()) |node| &node.view else null) == &one_a_pb.view);
        testing.expect(it.next() == null);
    }

    // Iteration over (pending) tags that aren't present
    {
        var it = ViewStack(View).pendingIterator(views.first, 1 << 2);
        testing.expect(it.next() == null);
    }
}
