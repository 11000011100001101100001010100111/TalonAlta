const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const process = std.process;
const fs = std.fs;

// --- CONFIG ---
const ROWS: usize = 24;
const COLS: usize = 80;
const VERSION = "v3.6.5 RESTORE";

const PhiloteNode = struct {
    url: []u8,
    weight: u32,
};

// --- SYSCALL PRIMITIVES ---
fn rawWrite(fd: i32, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        const written = try posix.write(fd, data[index..]);
        if (written == 0) return;
        index += written;
    }
}

fn rawPrint(data: []const u8) !void {
    try rawWrite(posix.STDOUT_FILENO, data);
}

fn rawPrintf(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const formatted_slice = try std.fmt.bufPrint(&buf, fmt, args);
    try rawPrint(formatted_slice);
}

fn getTermSize() std.posix.winsize {
    var ws = std.posix.winsize{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const TIOCGWINSZ = 0x5413;
    _ = std.os.linux.ioctl(posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));
    if (ws.row == 0) ws.row = 24;
    if (ws.col == 0) ws.col = 80;
    return ws;
}

// --- PHILOTE ENGINE ---
const PhiloteEngine = struct {
    nodes: std.ArrayListUnmanaged(PhiloteNode) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PhiloteEngine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PhiloteEngine) void {
        for (self.nodes.items) |node| self.allocator.free(node.url);
        self.nodes.deinit(self.allocator);
    }

    pub fn load(self: *PhiloteEngine) !void {
        const file = fs.cwd().openFile("philote.db", .{}) catch return;
        defer file.close();
        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);
        var iter = mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            var part_iter = mem.splitScalar(u8, line, '|');
            const url_part = part_iter.next() orelse continue;
            const weight_part = part_iter.next() orelse "0";
            const url = try self.allocator.dupe(u8, url_part);
            const weight = std.fmt.parseInt(u32, weight_part, 10) catch 0;
            try self.nodes.append(self.allocator, .{ .url = url, .weight = weight });
        }
        self.sort();
    }

    pub fn save(self: *PhiloteEngine) !void {
        const file = try fs.cwd().createFile("philote.db", .{});
        defer file.close();
        for (self.nodes.items) |node| {
            const line = try std.fmt.allocPrint(self.allocator, "{s}|{d}\n", .{node.url, node.weight});
            defer self.allocator.free(line);
            try file.writeAll(line);
        }
    }

    pub fn hit(self: *PhiloteEngine, target: []const u8) !void {
        for (self.nodes.items) |*node| {
            if (mem.eql(u8, node.url, target)) {
                node.weight += 1;
                self.sort();
                try self.save();
                return;
            }
        }
        const url = try self.allocator.dupe(u8, target);
        try self.nodes.append(self.allocator, .{ .url = url, .weight = 1 });
        self.sort();
        try self.save();
    }

    fn sort(self: *PhiloteEngine) void {
        const sortFn = struct {
            fn desc(context: void, a: PhiloteNode, b: PhiloteNode) bool {
                _ = context;
                return a.weight > b.weight;
            }
        }.desc;
        std.sort.block(PhiloteNode, self.nodes.items, {}, sortFn);
    }
};

// --- STATE ---
const AppState = struct {
    zoom: u8 = 2,
    url: []const u8 = "STANDBY",
    status: []const u8 = "IDLE",
    menu_open: bool = false,
    input_buffer: [256]u8 = undefined,
    input_len: usize = 0,
    scroll_y: usize = 0,
};

// --- MAIN ---
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const stdin_fd = posix.STDIN_FILENO;

    // --- RAW MODE INIT ---
    const original_termios = try posix.tcgetattr(stdin_fd);
    var raw = original_termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false; 
    raw.lflag.ISIG = false; 
    try posix.tcsetattr(stdin_fd, .NOW, raw);
    defer posix.tcsetattr(stdin_fd, .NOW, original_termios) catch {};

    try rawPrint("\x1b[2J\x1b[3J\x1b[H");

    var philote = PhiloteEngine.init(allocator);
    defer philote.deinit();
    try philote.load();

    var view_cache = std.ArrayListUnmanaged(u8){};
    defer view_cache.deinit(allocator);

    var state = AppState{};
    
    // Networking
    var child_ptr: ?process.Child = null;
    var fds = [2]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 },
    };

    // --- ARGS PAYLOAD PARSER ---
    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);
    if (args.len > 1) {
        const raw_payload = args[1];
        const payload = mem.trim(u8, raw_payload, "'");
        if (mem.startsWith(u8, payload, "@://")) {
            const target = payload[4..];
            state.url = try allocator.dupe(u8, target);
            state.status = "IGNITING PIPE";
            state.scroll_y = 0;
            try philote.hit(target);
            try connect(allocator, target, &child_ptr, &fds, &view_cache);
        }
    }

    try renderFrame(allocator, &state, view_cache.items, &philote);

    while (true) {
        _ = try posix.poll(&fds, -1);

        // --- INPUT LOOP ---
        if (fds[0].revents & posix.POLL.IN != 0) {
            var buf: [128]u8 = undefined;
            const n = try posix.read(stdin_fd, &buf);
            if (n == 0) break;

            var i: usize = 0;
            while (i < n) {
                const char = buf[i];

                // --- THE SILENCER (Escape Trap) ---
                if (char == 27) {
                    if (i + 2 < n and buf[i+1] == '[') {
                        const code = buf[i+2];
                        if (code == 'A') { 
                            if (state.scroll_y > 0) state.scroll_y -= 1;
                            i += 3; continue; 
                        }
                        if (code == 'B') { 
                            state.scroll_y += 1;
                            i += 3; continue; 
                        }
                        if (i + 3 < n and buf[i+3] == '~') {
                            if (code == '5') { 
                                if (state.scroll_y >= 20) state.scroll_y -= 20 else state.scroll_y = 0; 
                            }
                            if (code == '6') { 
                                state.scroll_y += 20; 
                            }
                            i += 4; continue;
                        }
                    } else {
                        // FRAGMENTATION HANDLER
                        var seq_buf: [3]u8 = undefined;
                        const seq_n = try posix.read(stdin_fd, &seq_buf);
                        if (seq_n > 0 and seq_buf[0] == '[') {
                            const code = seq_buf[1];
                            if (code == 'A') {
                                if (state.scroll_y > 0) state.scroll_y -= 1;
                            }
                            if (code == 'B') {
                                state.scroll_y += 1;
                            }
                            if (code == '5' and seq_n >= 3 and seq_buf[2] == '~') {
                                if (state.scroll_y >= 20) state.scroll_y -= 20 else state.scroll_y = 0;
                            }
                            if (code == '6' and seq_n >= 3 and seq_buf[2] == '~') {
                                state.scroll_y += 20;
                            }
                        }
                    }
                    i += 1; 
                    continue;
                }

                // --- BACKSPACE RESTORED ---
                if (char == 127) {
                    if (state.input_len > 0) state.input_len -= 1;
                    i += 1;
                    continue;
                }

                // Normal Input
                i += 1;

                if (char == '\t' or char == '`') {
                    state.menu_open = !state.menu_open;
                    continue;
                }

                if (char == '\n' or char == '\r') {
                    const cmd = state.input_buffer[0..state.input_len];
                    if (mem.eql(u8, cmd, "salud") or mem.eql(u8, cmd, "exit")) {
                        if (child_ptr) |*c| { _ = c.kill() catch {}; }
                        try rawPrint("\x1b[2J\x1b[H"); 
                        return;
                    }
                    if (mem.eql(u8, cmd, "@://reload")) {
                    } else if (mem.startsWith(u8, cmd, "@://")) {
                        const target = cmd[4..];
                        state.url = try allocator.dupe(u8, target);
                        state.scroll_y = 0;
                        state.status = "FETCHING";
                        try connect(allocator, target, &child_ptr, &fds, &view_cache);
                        try philote.hit(target);
                    }
                    state.input_len = 0;
                } else if (char >= 32 and char <= 126) {
                    if (state.input_len < 255) {
                        state.input_buffer[state.input_len] = char;
                        state.input_len += 1;
                    }
                }
            }
            try renderFrame(allocator, &state, view_cache.items, &philote);
        }

        // --- NETWORK LOOP ---
        if (fds[1].fd != -1 and (fds[1].revents & posix.POLL.IN != 0)) {
            var net_buf: [4096]u8 = undefined;
            const bytes = try posix.read(fds[1].fd, &net_buf);
            if (bytes == 0) {
                fds[1].fd = -1;
                state.status = "IDLE";
            } else {
                try view_cache.appendSlice(allocator, net_buf[0..bytes]);
            }
            if (!state.menu_open) try renderFrame(allocator, &state, view_cache.items, &philote);
        }
    }
}

// --- RENDERER ---
fn renderFrame(alloc: std.mem.Allocator, state: *AppState, content: []const u8, philote: *PhiloteEngine) !void {
    const ws = getTermSize();
    const term_h = ws.row;
    const term_w = ws.col;
    const view_h = if (term_h > 5) term_h - 5 else 5;

    try rawPrint("\x1b[2J\x1b[H");
    try rawPrint("\x1b[41;30m «高爪 TALON ALTA " ++ VERSION ++ "» \x1b[K\x1b[0m\n");

    if (state.menu_open) {
        try drawOverlay(philote);
    } else {
        if (content.len > 0) {
            try renderGrid(alloc, content, state.scroll_y, view_h, term_w, state.zoom);
        } else {
            if (mem.eql(u8, state.status, "FETCHING") or mem.eql(u8, state.status, "IGNITING PIPE")) {
                try rawPrint("\n\n   \x1b[90m[IGNITING...] Stream Active\x1b[0m\n");
            } else {
                try rawPrint("\n\n   \x1b[90m[STANDBY] TAB for Menu | @:// to Ignite\x1b[0m\n");
            }
        }
    }

    try rawPrintf("\x1b[{d};H", .{term_h - 1});
    try rawPrint("\x1b[41;30m");
    try rawPrintf(" Z:{d} | Y:{d} | {s} | [{s}] \x1b[K", .{ state.zoom, state.scroll_y, state.url, state.status });
    try rawPrint("\x1b[0m\n\x1b[1;37m> \x1b[0m");
    if (state.input_len > 0) try rawPrint(state.input_buffer[0..state.input_len]);
}

fn renderGrid(alloc: std.mem.Allocator, data: []const u8, scroll_y: usize, max_h: usize, max_w: u16, zoom: u8) !void {
    const C_RESET = "\x1b[0m";
    const C_TAG = "\x1b[90m";
    const C_TEXT = "\x1b[1;37m";
    const C_LINK = "\x1b[4;31m";

    var current_line: usize = 0;
    var col: u16 = 0;
    var lines_rendered: usize = 0;
    var context: u8 = 0;

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(alloc);

    for (data, 0..) |b, i| {
        if (current_line < scroll_y) {
            if (b == '\n') { current_line += 1; col = 0; }
            else {
                col += 1;
                if (col >= max_w) { current_line += 1; col = 0; }
            }
            continue;
        }

        if (lines_rendered >= max_h) break;

        if (b == '\n') {
            try out.append(alloc, b);
            lines_rendered += 1;
            col = 0;
            continue;
        }

        if (col >= max_w) {
            try out.append(alloc, '\n');
            lines_rendered += 1;
            col = 0;
            if (lines_rendered >= max_h) break;
        }

        col += 1;

        if (zoom == 3) { try out.append(alloc, b); continue; }

        if (b == '<') {
            try out.appendSlice(alloc, C_RESET);
            try out.appendSlice(alloc, C_TAG);
            try out.append(alloc, b);
            if (i + 1 < data.len) {
                const n = data[i+1];
                if (n == 'a' or n == 'A') {
                    context = 1;
                } else if (n == '/') {
                    context = 0;
                }
            }
        } else if (b == '>') {
            try out.append(alloc, b);
            const color = switch (context) { 1 => C_LINK, else => C_TEXT };
            try out.appendSlice(alloc, C_RESET);
            try out.appendSlice(alloc, color);
        } else {
            try out.append(alloc, b);
        }
    }
    try rawPrint(out.items);
}

fn drawOverlay(philote: *PhiloteEngine) !void {
    try rawPrint("\n\x1b[33m+--------------------------------+\x1b[0m\n");
    try rawPrint("\x1b[33m|        SYSTEM OVERLAY          |\x1b[0m\n");
    try rawPrint("\x1b[33m+--------------------------------+\x1b[0m\n");
    try rawPrint("| \x1b[1;37mARROWS\x1b[0m    Viewport Scroll      |\n");
    try rawPrint("| \x1b[1;37mPGUP/DN\x1b[0m   Turbo Scroll         |\n");
    try rawPrint("| \x1b[1;37m@://url\x1b[0m   Fetch New Target     |\n");
    try rawPrint("| \x1b[1;37msalud\x1b[0m      Halt Engine          |\n");
    try rawPrint("\x1b[33m+--------------------------------+\x1b[0m\n");
    try rawPrint("\x1b[31m[PHILOTE]\x1b[0m\n");
    var i: usize = 0; while (i < 5 and i < philote.nodes.items.len) : (i += 1) {
         try rawPrintf("  \x1b[33m#{d}\x1b[0m {s}\n", .{i+1, philote.nodes.items[i].url});
    }
}

fn connect(allocator: std.mem.Allocator, url: []const u8, child_ptr: *?process.Child, fds: *[2]posix.pollfd, cache: *std.ArrayListUnmanaged(u8)) !void {
    cache.clearRetainingCapacity();
    if (child_ptr.*) |*c| { _ = c.kill() catch {}; _ = c.wait() catch {}; child_ptr.* = null; fds[1].fd = -1; }
    // -N buffer-buster included
    const argv = [_][]const u8{ "curl", "-s", "-L", "-i", "-k", "-N", url };
    var child = process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch { return; };
    child_ptr.* = child;
    if (child.stdout) |stdout_pipe| fds[1].fd = stdout_pipe.handle;
}
