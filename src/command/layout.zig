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

const c = @import("../c.zig");

const Arg = @import("../Command.zig").Arg;
const Seat = @import("../Seat.zig");

pub fn layout(seat: *Seat, arg: Arg) void {
    const layout_name = arg.str;
    const config = seat.input_manager.server.config;
    seat.focused_output.layout = seat.focused_output.getLayoutByName(layout_name);
    seat.focused_output.arrangeViews();
    seat.input_manager.server.root.startTransaction();
}
