// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
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

const build_options = @import("build_options");
const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;

const log = @import("log.zig");
const util = @import("util.zig");

const Seat = @import("Seat.zig");
const Server = @import("Server.zig");
const View = @import("View.zig");

const default_seat_name = "default";

server: *Server,

idle: *wlr.Idle,
input_inhibit_manager: *wlr.InputInhibitManager,
virtual_pointer_manager: *wlr.VirtualPointerManagerV1,
virtual_keyboard_manager: *wlr.VirtualKeyboardManagerV1,

seats: std.TailQueue(Seat) = .{},

exclusive_client: ?*wl.Client = null,

inhibit_activate: wl.Listener(*wlr.InputInhibitManager) = undefined,
inhibit_deactivate: wl.Listener(*wlr.InputInhibitManager) = undefined,
new_input: wl.Listener(*wlr.InputDevice) = undefined,
new_virtual_pointer: wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer) = undefined,
new_virtual_keyboard: wl.Listener(*wlr.VirtualKeyboardV1) = undefined,

pub fn init(self: *Self, server: *Server) !void {
    const seat_node = try util.gpa.create(std.TailQueue(Seat).Node);
    errdefer util.gpa.destroy(seat_node);

    self.* = .{
        .server = server,
        // These are automatically freed when the display is destroyed
        .idle = try wlr.Idle.create(server.wl_server),
        .input_inhibit_manager = try wlr.InputInhibitManager.create(server.wl_server),
        .virtual_pointer_manager = try wlr.VirtualPointerManagerV1.create(server.wl_server),
        .virtual_keyboard_manager = try wlr.VirtualKeyboardManagerV1.create(server.wl_server),
    };

    self.seats.prepend(seat_node);
    try seat_node.data.init(self, default_seat_name);

    if (build_options.xwayland) server.xwayland.setSeat(self.defaultSeat().wlr_seat);

    self.inhibit_activate.setNotify(handleInhibitActivate);
    self.input_inhibit_manager.events.activate.add(&self.inhibit_activate);

    self.inhibit_deactivate.setNotify(handleInhibitDeactivate);
    self.input_inhibit_manager.events.deactivate.add(&self.inhibit_deactivate);

    self.new_input.setNotify(handleNewInput);
    self.server.backend.events.new_input.add(&self.new_input);

    self.new_virtual_pointer.setNotify(handleNewVirtualPointer);
    self.virtual_pointer_manager.events.new_virtual_pointer.add(&self.new_virtual_pointer);

    self.new_virtual_keyboard.setNotify(handleNewVirtualKeyboard);
    self.virtual_keyboard_manager.events.new_virtual_keyboard.add(&self.new_virtual_keyboard);
}

pub fn deinit(self: *Self) void {
    while (self.seats.pop()) |seat_node| {
        seat_node.data.deinit();
        util.gpa.destroy(seat_node);
    }
}

pub fn defaultSeat(self: Self) *Seat {
    return &self.seats.first.?.data;
}

/// Must be called whenever a view is unmapped.
pub fn handleViewUnmap(self: Self, view: *View) void {
    var it = self.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;
        seat.handleViewUnmap(view);
    }
}

/// Returns true if input is currently allowed on the passed surface.
pub fn inputAllowed(self: Self, wlr_surface: *wlr.Surface) bool {
    return if (self.exclusive_client) |exclusive_client|
        exclusive_client == wlr_surface.resource.getClient()
    else
        true;
}

pub fn isCursorActionTarget(self: Self, view: *View) bool {
    var it = self.seats.first;
    return while (it) |node| : (it = node.next) {
        if (node.data.cursor.isCursorActionTarget(view)) break true;
    } else false;
}

fn handleInhibitActivate(
    listener: *wl.Listener(*wlr.InputInhibitManager),
    input_inhibit_manager: *wlr.InputInhibitManager,
) void {
    const self = @fieldParentPtr(Self, "inhibit_activate", listener);

    log.debug(.input_manager, "input inhibitor activated", .{});

    var seat_it = self.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        // Clear focus of all seats
        seat_node.data.setFocusRaw(.{ .none = {} });

        // Enter locked mode
        seat_node.data.prev_mode_id = seat_node.data.mode_id;
        seat_node.data.mode_id = 1;
    }

    self.exclusive_client = self.input_inhibit_manager.active_client;
}

fn handleInhibitDeactivate(
    listener: *wl.Listener(*wlr.InputInhibitManager),
    input_inhibit_manager: *wlr.InputInhibitManager,
) void {
    const self = @fieldParentPtr(Self, "inhibit_deactivate", listener);

    log.debug(.input_manager, "input inhibitor deactivated", .{});

    self.exclusive_client = null;

    // Calling arrangeLayers() like this ensures that any top or overlay,
    // keyboard-interactive surfaces will re-grab focus.
    var output_it = self.server.root.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        output_node.data.arrangeLayers();
    }

    // After ensuring that any possible layer surface focus grab has occured,
    // have each Seat handle focus and enter their previous mode.
    var seat_it = self.seats.first;
    while (seat_it) |seat_node| : (seat_it = seat_node.next) {
        seat_node.data.focus(null);
        seat_node.data.mode_id = seat_node.data.prev_mode_id;
    }

    self.server.root.startTransaction();
}

/// This event is raised by the backend when a new input device becomes available.
fn handleNewInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
    const self = @fieldParentPtr(Self, "new_input", listener);
    // TODO: suport multiple seats
    self.defaultSeat().addDevice(device);
}

fn handleNewVirtualPointer(
    listener: *wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer),
    event: *wlr.VirtualPointerManagerV1.event.NewPointer,
) void {
    const self = @fieldParentPtr(Self, "new_virtual_pointer", listener);

    // TODO Support multiple seats and don't ignore
    if (event.suggested_seat != null) {
        log.debug(.input_manager, "Ignoring seat suggestion from virtual pointer", .{});
    }
    // TODO dont ignore output suggestion
    if (event.suggested_output != null) {
        log.debug(.input_manager, "Ignoring output suggestion from virtual pointer", .{});
    }

    self.defaultSeat().addDevice(&event.new_pointer.input_device);
}

fn handleNewVirtualKeyboard(
    listener: *wl.Listener(*wlr.VirtualKeyboardV1),
    virtual_keyboard: *wlr.VirtualKeyboardV1,
) void {
    const self = @fieldParentPtr(Self, "new_virtual_keyboard", listener);
    const seat = @intToPtr(*Seat, virtual_keyboard.seat.data);
    seat.addDevice(&virtual_keyboard.input_device);
}
