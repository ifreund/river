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

const Self = @This();

const std = @import("std");

const c = @import("c.zig");

const Box = @import("Box.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XdgPopup = @import("XdgPopup.zig");

/// The view this xwayland view implements
view: *View,

/// The corresponding wlroots object
wlr_xwayland_surface: *c.wlr_xwayland_surface,

// Listeners that are always active over the view's lifetime
listen_destroy: c.wl_listener,
listen_map: c.wl_listener,
listen_unmap: c.wl_listener,

// Listeners that are only active while the view is mapped
listen_commit: c.wl_listener,

pub fn init(self: *Self, view: *View, wlr_xwayland_surface: *c.wlr_xwayland_surface) void {
    self.view = view;
    self.wlr_xwayland_surface = wlr_xwayland_surface;
    wlr_xwayland_surface.data = self;

    // Add listeners that are active over the view's entire lifetime
    self.listen_destroy.notify = handleDestroy;
    c.wl_signal_add(&self.wlr_xwayland_surface.events.destroy, &self.listen_destroy);

    self.listen_map.notify = handleMap;
    c.wl_signal_add(&self.wlr_xwayland_surface.events.map, &self.listen_map);

    self.listen_unmap.notify = handleUnmap;
    c.wl_signal_add(&self.wlr_xwayland_surface.events.unmap, &self.listen_unmap);
}

pub fn needsConfigure(self: Self) bool {
    return self.wlr_xwayland_surface.x != self.view.pending.box.x or
        self.wlr_xwayland_surface.y != self.view.pending.box.y or
        self.wlr_xwayland_surface.width != self.view.pending.box.width or
        self.wlr_xwayland_surface.height != self.view.pending.box.height;
}

/// Tell the client to take a new size
pub fn configure(self: Self, pending_box: Box) void {
    c.wlr_xwayland_surface_configure(
        self.wlr_xwayland_surface,
        @intCast(i16, pending_box.x),
        @intCast(i16, pending_box.y),
        @intCast(u16, pending_box.width),
        @intCast(u16, pending_box.height),
    );
    // Xwayland surfaces don't use serials, so we will just assume they have
    // configured the next time they commit. Set pending serial to a dummy
    // value to indicate that a transaction has started. Note: we can't just
    // call notifyConfigured() here as the transaction has not yet been fully
    // initiated.
    self.view.pending_serial = 0x66666666;
}

/// Inform the xwayland surface that it has gained focus
pub fn setActivated(self: Self, activated: bool) void {
    c.wlr_xwayland_surface_activate(self.wlr_xwayland_surface, activated);
}

pub fn setFullscreen(self: Self, fullscreen: bool) void {
    c.wlr_xwayland_surface_set_fullscreen(self.wlr_xwayland_surface, fullscreen);
}

/// Close the view. This will lead to the unmap and destroy events being sent
pub fn close(self: Self) void {
    c.wlr_xwayland_surface_close(self.wlr_xwayland_surface);
}

/// Iterate over all surfaces of the xwayland view.
pub fn forEachSurface(
    self: Self,
    iterator: c.wlr_surface_iterator_func_t,
    user_data: ?*c_void,
) void {
    c.wlr_surface_for_each_surface(self.wlr_xwayland_surface.surface, iterator, user_data);
}

/// Return the surface at output coordinates ox, oy and set sx, sy to the
/// corresponding surface-relative coordinates, if there is a surface.
pub fn surfaceAt(self: Self, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*c.wlr_surface {
    return c.wlr_surface_surface_at(
        self.wlr_xwayland_surface.surface,
        ox - @intToFloat(f64, self.view.current.box.x),
        oy - @intToFloat(f64, self.view.current.box.y),
        sx,
        sy,
    );
}

/// Get the current title of the xwayland surface. May be an empty string
pub fn getTitle(self: Self) [*:0]const u8 {
    return self.wlr_xwayland_surface.title orelse "";
}

/// Return bounds on the dimensions of the view
pub fn getConstraints(self: Self) View.Constraints {
    const hints: *c.wlr_xwayland_surface_size_hints = self.wlr_xwayland_surface.size_hints orelse return .{
        .min_width = View.min_size,
        .max_width = std.math.maxInt(u32),
        .min_height = View.min_size,
        .max_height = std.math.maxInt(u32),
    };
    return .{
        .min_width = if (hints.min_width > 0) @intCast(u32, hints.min_width) else View.min_size,
        .max_width = if (hints.max_width > 0) @intCast(u32, hints.max_width) else std.math.maxInt(u32),
        .min_height = if (hints.min_height > 0) @intCast(u32, hints.min_height) else View.min_size,
        .max_height = if (hints.max_height > 0) @intCast(u32, hints.max_height) else std.math.maxInt(u32),
    };
}

/// Called when the xwayland surface is destroyed
fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_destroy", listener.?);

    // Remove listeners that are active for the entire lifetime of the view
    c.wl_list_remove(&self.listen_destroy.link);
    c.wl_list_remove(&self.listen_map.link);
    c.wl_list_remove(&self.listen_unmap.link);

    self.view.destroy();
}

/// Called when the xwayland surface is mapped, or ready to display on-screen.
fn handleMap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_map", listener.?);
    const view = self.view;
    const root = view.output.root;

    // Add listeners that are only active while mapped
    self.listen_commit.notify = handleCommit;
    c.wl_signal_add(&self.wlr_xwayland_surface.surface.*.events.commit, &self.listen_commit);

    view.wlr_surface = self.wlr_xwayland_surface.surface;

    // Use the view's "natural" size centered on the output as the default
    // floating dimensions
    view.float_box.width = self.wlr_xwayland_surface.width;
    view.float_box.height = self.wlr_xwayland_surface.height;
    view.float_box.x = std.math.max(0, @divTrunc(@intCast(i32, view.output.usable_box.width) -
        @intCast(i32, view.float_box.width), 2));
    view.float_box.y = std.math.max(0, @divTrunc(@intCast(i32, view.output.usable_box.height) -
        @intCast(i32, view.float_box.height), 2));

    view.map();
}

/// Called when the surface is unmapped and will no longer be displayed.
fn handleUnmap(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_unmap", listener.?);

    self.view.unmap();

    // Remove listeners that are only active while mapped
    c.wl_list_remove(&self.listen_commit.link);
}

/// Called when the surface is comitted
/// TODO: check for unexpected change in size and react as needed
fn handleCommit(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_commit", listener.?);
    const view = self.view;

    view.surface_box = Box{
        .x = 0,
        .y = 0,
        .width = @intCast(u32, self.wlr_xwayland_surface.surface.*.current.width),
        .height = @intCast(u32, self.wlr_xwayland_surface.surface.*.current.height),
    };

    // See comment in XwaylandView.configure()
    if (view.pending_serial != null) {
        // If the view is part of the layout, notify the transaction code. If
        // the view is floating or fullscreen apply the pending state immediately.
        view.pending_serial = null;
        if (!view.pending.float and !view.pending.fullscreen)
            view.output.root.notifyConfigured()
        else
            view.current = view.pending;
    }
}
