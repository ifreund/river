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

const std = @import("std");
const wlr = @import("wlroots");
const wl = @import("wayland").server.wl;
const xkb = @import("xkbcommon");

const log = @import("log.zig");
const util = @import("util.zig");

const Seat = @import("Seat.zig");

seat: *Seat,
input_device: *wlr.InputDevice,

key: wl.Listener(*wlr.Keyboard.event.Key) = undefined,
modifiers: wl.Listener(*wlr.Keyboard) = undefined,
destroy: wl.Listener(*wlr.Keyboard) = undefined,

pub fn init(self: *Self, seat: *Seat, input_device: *wlr.InputDevice) !void {
    self.* = .{
        .seat = seat,
        .input_device = input_device,
    };

    // We need to prepare an XKB keymap and assign it to the keyboard. This
    // assumes the defaults (e.g. layout = "us").
    const rules = xkb.RuleNames{
        .rules = null,
        .model = null,
        .layout = null,
        .variant = null,
        .options = null,
    };
    const context = xkb.Context.new(.no_flags) orelse return error.XkbContextFailed;
    defer context.unref();

    const keymap = xkb.Keymap.newFromNames(context, &rules, .no_flags) orelse return error.XkbKeymapFailed;
    defer keymap.unref();

    const wlr_keyboard = self.input_device.device.keyboard;

    if (!wlr_keyboard.setKeymap(keymap)) return error.SetKeymapFailed;
    wlr_keyboard.setRepeatInfo(25, 600);

    self.key.setNotify(handleKey);
    wlr_keyboard.events.key.add(&self.key);

    self.modifiers.setNotify(handleModifiers);
    wlr_keyboard.events.modifiers.add(&self.modifiers);

    self.destroy.setNotify(handleDestroy);
    wlr_keyboard.events.destroy.add(&self.destroy);
}

pub fn deinit(self: *Self) void {
    self.key.link.remove();
    self.modifiers.link.remove();
    self.destroy.link.remove();
}

fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
    // This event is raised when a key is pressed or released.
    const self = @fieldParentPtr(Self, "key", listener);
    const wlr_keyboard = self.input_device.device.keyboard;

    self.seat.handleActivity();

    // Translate libinput keycode -> xkbcommon
    const keycode = event.keycode + 8;

    // TODO: These modifiers aren't properly handled, see sway's code
    const modifiers = wlr_keyboard.getModifiers();
    const released = event.state == .released;

    var handled = false;

    // First check translated keysyms as xkb reports them
    for (wlr_keyboard.xkb_state.?.keyGetSyms(keycode)) |sym| {
        // Handle builtin mapping only when keys are pressed
        if (!released and self.handleBuiltinMapping(sym)) {
            handled = true;
            break;
        } else if (self.seat.handleMapping(sym, modifiers, released)) {
            handled = true;
            break;
        }
    }

    // If not yet handled, check keysyms ignoring modifiers (e.g. 1 instead of !)
    // Important for mappings like Mod+Shift+1
    if (!handled) {
        const layout_index = wlr_keyboard.xkb_state.?.keyGetLayout(keycode);
        for (wlr_keyboard.keymap.?.keyGetSymsByLevel(keycode, layout_index, 0)) |sym| {
            // Handle builtin mapping only when keys are pressed
            if (!released and self.handleBuiltinMapping(sym)) {
                handled = true;
                break;
            } else if (self.seat.handleMapping(sym, modifiers, released)) {
                handled = true;
                break;
            }
        }
    }

    if (!handled) {
        // Otherwise, we pass it along to the client.
        const wlr_seat = self.seat.wlr_seat;
        wlr_seat.setKeyboard(self.input_device);
        wlr_seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
    }
}

/// Simply pass modifiers along to the client
fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
    const self = @fieldParentPtr(Self, "modifiers", listener);

    self.seat.wlr_seat.setKeyboard(self.input_device);
    self.seat.wlr_seat.keyboardNotifyModifiers(&self.input_device.device.keyboard.modifiers);
}

fn handleDestroy(listener: *wl.Listener(*wlr.Keyboard), wlr_keyboard: *wlr.Keyboard) void {
    const self = @fieldParentPtr(Self, "destroy", listener);
    const node = @fieldParentPtr(std.TailQueue(Self).Node, "data", self);

    self.seat.keyboards.remove(node);
    self.deinit();
    util.gpa.destroy(node);
}

/// Handle any builtin, harcoded compsitor mappings such as VT switching.
/// Returns true if the keysym was handled.
fn handleBuiltinMapping(self: Self, keysym: xkb.Keysym) bool {
    switch (@enumToInt(keysym)) {
        @enumToInt(xkb.Keysym.XF86Switch_VT_1)...@enumToInt(xkb.Keysym.XF86Switch_VT_12) => {
            log.debug(.keyboard, "switch VT keysym received", .{});
            const backend = self.seat.input_manager.server.backend;
            if (backend.isMulti()) {
                if (backend.getSession()) |session| {
                    const vt = @enumToInt(keysym) - @enumToInt(xkb.Keysym.XF86Switch_VT_1) + 1;
                    log.notice(.server, "switching to VT {}", .{vt});
                    session.changeVt(vt) catch log.err(.server, "changing VT failed", .{});
                }
            }
            return true;
        },
        else => return false,
    }
}
