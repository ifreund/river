// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Leon Henrik Plickat
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

const std = @import("std");

const Error = @import("../command.zig").Error;
const Seat = @import("../Seat.zig");
const View = @import("../View.zig");
const ViewStack = @import("../view_stack.zig").ViewStack;

fn opacityUpdateFilter(view: *View, context: void) bool {
    // We want to update all views
    return true;
}

pub fn opacity(
    allocator: *std.mem.Allocator,
    seat: *Seat,
    args: []const []const u8,
    out: *?[]const u8,
) Error!void {
    if (args.len < 6) return Error.NotEnoughArguments;
    if (args.len > 6) return Error.TooManyArguments;

    const server = seat.input_manager.server;

    // Focused opacity
    server.config.view_opacity_focused = try std.fmt.parseFloat(f32, args[1]);
    if (server.config.view_opacity_focused < 0.0 or server.config.view_opacity_focused > 1.0)
        return Error.InvalidValue;

    // Unfocused opacity
    server.config.view_opacity_unfocused = try std.fmt.parseFloat(f32, args[2]);
    if (server.config.view_opacity_unfocused < 0.0 or server.config.view_opacity_unfocused > 1.0)
        return Error.InvalidValue;

    // Starting opacity for new views
    server.config.view_opacity_initial = try std.fmt.parseFloat(f32, args[3]);
    if (server.config.view_opacity_initial < 0.0 or server.config.view_opacity_initial > 1.0)
        return Error.InvalidValue;

    // Opacity transition step
    server.config.view_opacity_delta = try std.fmt.parseFloat(f32, args[4]);
    if (server.config.view_opacity_delta < 0.0 or server.config.view_opacity_delta > 1.0)
        return Error.InvalidValue;

    // Time between step
    server.config.view_opacity_delta_t = try std.fmt.parseInt(u31, args[5], 10);
    if (server.config.view_opacity_delta_t < 1) return Error.InvalidValue;

    // Update opacity of all views
    // Unmapped views will be skipped, however their opacity gets updated on map anyway
    var oit = server.root.outputs.first;
    while (oit) |onode| : (oit = onode.next) {
        var vit = ViewStack(View).iter(onode.data.views.first, .forward, {}, opacityUpdateFilter);
        while (vit.next()) |vnode| {
            if (vnode.current.focus > 0) {
                vnode.pending.target_opacity = server.config.view_opacity_focused;
            } else {
                vnode.pending.target_opacity = server.config.view_opacity_unfocused;
            }
        }
    }
    server.root.startTransaction();
}
