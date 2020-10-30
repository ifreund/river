#ifndef RIVER_BINDINGS_H
#define RIVER_BINDINGS_H

#include <wlr/backend/session.h>

/*
 * This header is needed since zig cannot yet translate flexible arrays.
 * See https://github.com/ziglang/zig/issues/4775
 */

struct wlr_backend *river_wlr_backend_autocreate(struct wl_display *display);
struct wlr_renderer *river_wlr_backend_get_renderer(struct wlr_backend *backend);

#endif // RIVER_BINDINGS_H
