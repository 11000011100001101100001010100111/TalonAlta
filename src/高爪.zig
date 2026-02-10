const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const process = std.process;
const fs = std.fs;

// --- CONFIG ---
const ROWS: usize = 24;
const COLS: usize = 80;
const VERSION = "v3.10.2 HEX-FIX";

// --- ANSI PROTOCOL (@NSIBLE-RED) ---
const C_RESET = "\x1b[0m";
const C_TAG   = "\x1b[31m";   // CRIMSON (Tags)
const C_LINK  = "\x1b[33m";   // BRASS (Links)
const C_TEXT  = "\x1b[37m";   // SILVER (Text)
const C_SCAN  = "\x1b[7m";    // INVERSE (Scanner Focus)
const C_BAR   = "\x1b[41;30m";// RED BG / BLACK FG
const C_META  = "\x1b[36m";   // CYAN (Metadata)
const C_LASER = "\x1b[41;37m";// RED BG / WHITE FG (Scan Line)

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

fn sysSleep(ms: i32) void {
    var fds = [0]posix.pollfd{};
    _ = posix.poll(&fds, ms) catch {};
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
    scope: i8 = 1, 
    url: []const u8 = "STANDBY",
    status: []const u8 = "IDLE",
    menu_open: bool = false,
    input_buffer: [256]u8 = undefined,
    input_len: usize = 0,
    scroll_y: usize = 0,
    scan_line: usize = 0,
    raw_mode: bool = false, 
    bytes_rx: usize = 0,
    history: std.ArrayListUnmanaged([]u8) = .{},
};

// --- SPLASH ---
fn drawSplash() !void {
    const LOGO = [_][]const u8{
        "      .---.      ",
        "     /     \\     ",
        "    |  (O)  |    ",
        "     \\     /     ",
        "      '---'      ",
        "",
        " @NSIBLE SECURE UPLINK",
        " [|||||||||||||] 100%"
    };
    try rawPrint("\x1b[2J\x1b[H\n");
    var i: usize = 0;
    while (i < LOGO.len + 4) : (i += 1) {
        try rawPrint("\x1b[H\n");
        var row: usize = 0;
        while (row < LOGO.len) : (row += 1) {
            if (row == i) {
                try rawPrint(C_LASER); try rawPrint(LOGO[row]); try rawPrint("\x1b[K" ++ C_RESET ++ "\n");
            } else if (row < i) {
                try rawPrint(C_TAG); try rawPrint(LOGO[row]); try rawPrint(C_RESET ++ "\n");
            } else {
                try rawPrint("\n");
            }
        }
        try rawPrint("\n  " ++ C_TEXT ++ "Initializing Core..." ++ C_RESET);
        sysSleep(60); 
    }
    sysSleep(200);
}

// --- MAIN ---
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const stdin_fd = posix.STDIN_FILENO;

    const original_termios = try posix.tcgetattr(stdin_fd);
    var raw = original_termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false; 
    raw.lflag.ISIG = false; 
    try posix.tcsetattr(stdin_fd, .NOW, raw);
    defer posix.tcsetattr(stdin_fd, .NOW, original_termios) catch {};

    try drawSplash();
    try rawPrint("\x1b[2J\x1b[3J\x1b[H");

    var philote = PhiloteEngine.init(allocator);
    defer philote.deinit();
    try philote.load();

    var raw_cache = std.ArrayListUnmanaged(u8){};
    var display_cache = std.ArrayListUnmanaged(u8){}; 
    defer raw_cache.deinit(allocator);
    defer display_cache.deinit(allocator);

    var state = AppState{};
    
    var child_ptr: ?process.Child = null;
    var fds = [2]posix.pollfd{
        .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 },
    };

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);
    if (args.len > 1) {
        const raw_payload = args[1];
        const payload = mem.trim(u8, raw_payload, "'");
        if (mem.startsWith(u8, payload, "@://")) {
            const target = payload[4..];
            try navigate(allocator, &state, target, &child_ptr, &fds, &raw_cache, &philote, false);
        }
    }

    // --- TURBO DRAIN ---
    if (fds[1].fd != -1) {
        var net_buf: [4096]u8 = undefined;
        var drain_loop: usize = 0;
        while (drain_loop < 20) : (drain_loop += 1) {
            const count = posix.poll(&fds, 0) catch 0;
            if (count > 0 and (fds[1].revents & posix.POLL.IN != 0)) {
                 const bytes = posix.read(fds[1].fd, &net_buf) catch 0;
                 if (bytes > 0) {
                     try raw_cache.appendSlice(allocator, net_buf[0..bytes]);
                     state.bytes_rx += bytes;
                 } else { break; }
            } else { break; }
        }
        if (state.bytes_rx > 0) {
            try computeDisplayView(allocator, raw_cache.items, &display_cache, &state);
        }
    }

    try renderFrame(allocator, &state, display_cache.items, &philote);

    while (true) {
        _ = try posix.poll(&fds, 100);
        const ws = getTermSize();
        const view_h = if (ws.row > 5) ws.row - 5 else 5;

        // --- INPUT LOOP ---
        if (fds[0].revents & posix.POLL.IN != 0) {
            var buf: [128]u8 = undefined;
            const n = try posix.read(stdin_fd, &buf);
            if (n == 0) break;

            var i: usize = 0;
            while (i < n) {
                const char = buf[i];

                if (char == 27) {
                    if (i + 2 < n and buf[i+1] == '[') {
                        const code = buf[i+2];
                        if (code == 'A') { if (state.scan_line > 0) { state.scan_line -= 1; if (state.scan_line < state.scroll_y) state.scroll_y = state.scan_line; } i += 3; continue; }
                        if (code == 'B') { state.scan_line += 1; if (state.scan_line >= state.scroll_y + view_h) { state.scroll_y = state.scan_line - view_h + 1; } i += 3; continue; }
                        if (code == 'D') { state.scan_line = findPrevLink(display_cache.items, state.scan_line); if (state.scan_line < state.scroll_y) state.scroll_y = state.scan_line; i += 3; continue; }
                        if (code == 'C') { state.scan_line = findNextLink(display_cache.items, state.scan_line); if (state.scan_line >= state.scroll_y + view_h) state.scroll_y = state.scan_line - view_h + 1; i += 3; continue; }
                        if (i + 3 < n and buf[i+3] == '~') {
                            const jump = view_h;
                            if (code == '5') { if (state.scan_line >= jump) state.scan_line -= jump else state.scan_line = 0; if (state.scan_line < state.scroll_y) state.scroll_y = state.scan_line; }
                            if (code == '6') { state.scan_line += jump; if (state.scan_line >= state.scroll_y + view_h) state.scroll_y = state.scan_line - view_h + 1; }
                            i += 4; continue;
                        }
                    } 
                    i += 1; continue;
                }

                if (char == 127) { if (state.input_len > 0) state.input_len -= 1; i += 1; continue; }
                if (char == '\t') { state.menu_open = !state.menu_open; i += 1; continue; }

                if (char == '\n' or char == '\r') {
                    const cmd = state.input_buffer[0..state.input_len];
                    
                    if (state.input_len == 0) {
                        const url = extractUrlFromLine(allocator, display_cache.items, state.scan_line);
                        if (url) |u| {
                            state.status = "LINK DETECTED";
                            try navigate(allocator, &state, u, &child_ptr, &fds, &raw_cache, &philote, true);
                        }
                    } else {
                        // COMMANDS
                        if (mem.eql(u8, cmd, "salud")) return;
                        if (mem.eql(u8, cmd, "@://z+")) {
                            if (state.scope < 2) {
                                state.scope += 1;
                                if (state.scope == 2) { try launchDevice(allocator, state.url); state.scope = 1; } 
                                else try computeDisplayView(allocator, raw_cache.items, &display_cache, &state);
                            }
                        }
                        else if (mem.eql(u8, cmd, "@://z-")) {
                            if (state.scope > -1) {
                                state.scope -= 1;
                                try computeDisplayView(allocator, raw_cache.items, &display_cache, &state);
                            }
                        }
                        else if (mem.eql(u8, cmd, "@://x+")) { state.raw_mode = true; try computeDisplayView(allocator, raw_cache.items, &display_cache, &state); }
                        else if (mem.eql(u8, cmd, "@://x-")) { state.raw_mode = false; try computeDisplayView(allocator, raw_cache.items, &display_cache, &state); }
                        else if (mem.eql(u8, cmd, "@://reload")) { try navigate(allocator, &state, state.url, &child_ptr, &fds, &raw_cache, &philote, false); }
                        else if (mem.eql(u8, cmd, "@://back")) { if (state.history.items.len > 1) { _ = state.history.pop(); const prev = state.history.pop().?; try navigate(allocator, &state, prev, &child_ptr, &fds, &raw_cache, &philote, false); } }
                        else if (mem.startsWith(u8, cmd, "@://")) { const target = cmd[4..]; try navigate(allocator, &state, target, &child_ptr, &fds, &raw_cache, &philote, true); }
                        state.input_len = 0;
                    }
                } else if (char >= 32 and char <= 126) {
                    if (state.input_len < 255) { state.input_buffer[state.input_len] = char; state.input_len += 1; }
                }
                i += 1;
            }
            try renderFrame(allocator, &state, display_cache.items, &philote);
        }

        // --- NETWORK LOOP ---
        if (fds[1].fd != -1 and (fds[1].revents & posix.POLL.IN != 0)) {
            var net_buf: [4096]u8 = undefined;
            const bytes = try posix.read(fds[1].fd, &net_buf);
            if (bytes == 0) {
                fds[1].fd = -1;
                state.status = "IDLE";
                try computeDisplayView(allocator, raw_cache.items, &display_cache, &state);
            } else {
                try raw_cache.appendSlice(allocator, net_buf[0..bytes]);
                state.bytes_rx += bytes;
                try computeDisplayView(allocator, raw_cache.items, &display_cache, &state);
            }
            if (!state.menu_open) try renderFrame(allocator, &state, display_cache.items, &philote);
        }
    }
}

// --- LOGIC ---

fn launchDevice(alloc: std.mem.Allocator, url: []const u8) !void {
    const full_url = if (mem.startsWith(u8, url, "http")) url else try std.fmt.allocPrint(alloc, "https://{s}", .{url});
    const argv = [_][]const u8{ "am", "start", "-a", "android.intent.action.VIEW", "-d", full_url };
    var child = process.Child.init(&argv, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch {};
    _ = child.wait() catch {};
}

fn computeDisplayView(alloc: std.mem.Allocator, raw: []const u8, display: *std.ArrayListUnmanaged(u8), state: *AppState) !void {
    display.clearRetainingCapacity();
    
    var split_idx: usize = 0;
    if (mem.indexOf(u8, raw, "\r\n\r\n")) |idx| { split_idx = idx; }
    else if (mem.indexOf(u8, raw, "\n\n")) |idx| { split_idx = idx; }

    // HEX DUMP (Corrected 'const')
    if (state.scope == -1) {
        var i: usize = 0;
        while (i < raw.len) {
            const chunk_len = if (i + 16 > raw.len) raw.len - i else 16;
            const chunk = raw[i .. i + chunk_len];
            const line = try std.fmt.allocPrint(alloc, "{x:0>8} | ", .{i});
            try display.appendSlice(alloc, line);
            for (chunk) |b| {
                const hex = try std.fmt.allocPrint(alloc, "{x:0>2} ", .{b});
                try display.appendSlice(alloc, hex);
            }
            var p: usize = chunk_len;
            while (p < 16) : (p += 1) { try display.appendSlice(alloc, "   "); }
            try display.appendSlice(alloc, "| ");
            for (chunk) |b| {
                const c = if (b >= 32 and b <= 126) b else '.';
                try display.append(alloc, c);
            }
            try display.append(alloc, '\n');
            i += 16;
        }
        return;
    }

    if (state.scope == 0) {
        if (split_idx > 0) {
            try display.appendSlice(alloc, C_META);
            try display.appendSlice(alloc, raw[0..split_idx]);
            try display.appendSlice(alloc, C_RESET);
        } else {
            try display.appendSlice(alloc, "[NO METADATA]");
        }
        return;
    }

    const body = if (split_idx > 0) raw[split_idx..] else raw;
    
    if (state.raw_mode) {
        try display.appendSlice(alloc, body);
        return;
    }

    var i: usize = 0;
    while (i < body.len) {
        if (i + 5 < body.len and mem.eql(u8, body[i..i+5], "<pre>")) {
            try display.appendSlice(alloc, C_LINK ++ "[+] SENTINEL: Code Collapsed (@://x+ to view)" ++ C_RESET ++ "\n");
            i += 5;
            while (i < body.len) {
                if (i + 6 < body.len and mem.eql(u8, body[i..i+6], "</pre>")) { i += 6; break; }
                i += 1;
            }
        } else {
            try display.append(alloc, body[i]);
            i += 1;
        }
    }
}

fn findNextLink(data: []const u8, current_line: usize) usize {
    var line_idx: usize = 0;
    var iter = mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        if (line_idx > current_line) {
            if (mem.indexOf(u8, line, "http") != null or mem.indexOf(u8, line, "@://") != null) return line_idx;
        }
        line_idx += 1;
    }
    return current_line;
}

fn findPrevLink(data: []const u8, current_line: usize) usize {
    if (current_line == 0) return 0;
    var line_idx: usize = 0;
    var iter = mem.splitScalar(u8, data, '\n');
    var last_link_line: usize = 0;
    while (iter.next()) |line| {
        if (line_idx >= current_line) break;
        if (mem.indexOf(u8, line, "http") != null or mem.indexOf(u8, line, "@://") != null) last_link_line = line_idx;
        line_idx += 1;
    }
    return last_link_line;
}

fn navigate(alloc: std.mem.Allocator, state: *AppState, target: []const u8, child_ptr: *?process.Child, fds: *[2]posix.pollfd, cache: *std.ArrayListUnmanaged(u8), philote: *PhiloteEngine, push_history: bool) !void {
    state.url = try alloc.dupe(u8, target);
    state.scroll_y = 0; state.scan_line = 0; state.status = "FETCHING"; state.bytes_rx = 0;
    cache.clearRetainingCapacity(); 
    if (push_history) try state.history.append(alloc, try alloc.dupe(u8, target));
    try philote.hit(target);
    try connect(alloc, target, child_ptr, fds);
}

fn extractUrlFromLine(alloc: std.mem.Allocator, data: []const u8, target_line: usize) ?[]u8 {
    var current_line: usize = 0;
    var iter = mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        if (current_line == target_line) {
            if (mem.indexOf(u8, line, "http")) |start| {
                var end = start;
                while (end < line.len) : (end += 1) {
                    const c = line[end];
                    if (c == ' ' or c == '"' or c == '\'' or c == ')' or c == '>') break;
                }
                return alloc.dupe(u8, line[start..end]) catch null;
            }
             if (mem.indexOf(u8, line, "@://")) |start| {
                var end = start;
                while (end < line.len) : (end += 1) {
                    const c = line[end];
                    if (c == ' ' or c == '"') break;
                }
                 return alloc.dupe(u8, line[start+4..end]) catch null;
            }
            return null;
        }
        current_line += 1;
    }
    return null;
}

fn renderFrame(alloc: std.mem.Allocator, state: *AppState, content: []const u8, philote: *PhiloteEngine) !void {
    const ws = getTermSize();
    const term_h = ws.row;
    const term_w = ws.col;
    const view_h = if (term_h > 5) term_h - 5 else 5;

    try rawPrint("\x1b[2J\x1b[H");
    try rawPrint(C_BAR ++ " :: 高爪 TALON ALTA " ++ VERSION ++ " :: \x1b[K" ++ C_RESET ++ "\n");

    if (state.menu_open) {
        try drawOverlay(philote);
    } else {
        if (content.len > 0) {
            try renderGrid(alloc, content, state.scroll_y, state.scan_line, view_h, term_w);
        } else {
            if (mem.eql(u8, state.status, "FETCHING")) {
                 try rawPrint("\n\n   " ++ C_LINK ++ "[  LOADING DATA STREAM...  ]" ++ C_RESET ++ "\n");
                 try rawPrintf("   BYTES RECEIVED: {d}\n", .{state.bytes_rx});
            } else {
                 try rawPrint("\n\n   " ++ C_TAG ++ "[STANDBY]" ++ C_TEXT ++ " Type @://url | Arrows to Scan | @://z+/- Scope\n");
            }
        }
    }

    try rawPrintf("\x1b[{d};H", .{term_h - 1});
    try rawPrint(C_BAR); 
    
    var mode_buf: [32]u8 = undefined;
    var mode_str: []u8 = undefined;
    if (state.scope == 2) mode_str = try std.fmt.bufPrint(&mode_buf, "EXTERNAL", .{})
    else if (state.scope == 1) mode_str = try std.fmt.bufPrint(&mode_buf, "{s}", .{if (state.raw_mode) "RAW" else "SENTINEL"})
    else if (state.scope == 0) mode_str = try std.fmt.bufPrint(&mode_buf, "METADATA", .{})
    else mode_str = try std.fmt.bufPrint(&mode_buf, "BINARY HEX", .{});

    try rawPrintf(" SCOPE: {s} | L:{d} | [{s}] \x1b[K", .{ mode_str, state.scan_line, state.status });
    
    try rawPrint(C_RESET ++ "\n" ++ C_TEXT ++ "> " ++ C_RESET);
    if (state.input_len > 0) try rawPrint(state.input_buffer[0..state.input_len]);
}

fn renderGrid(alloc: std.mem.Allocator, data: []const u8, scroll_y: usize, scan_line: usize, max_h: usize, max_w: u16) !void {
    var current_line: usize = 0;
    var col: u16 = 0;
    var lines_rendered: usize = 0;
    var context: u8 = 0; 
    
    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(alloc);

    if (data.len == 0) return;

    var is_scanning = (current_line == scan_line);
    
    if (is_scanning) try out.appendSlice(alloc, C_SCAN);
    try out.appendSlice(alloc, C_TEXT);

    for (data, 0..) |b, i| {
        if (current_line < scroll_y) {
            if (b == '\n') { current_line += 1; col = 0; is_scanning = (current_line == scan_line); }
            else { col += 1; if (col >= max_w) { current_line += 1; col = 0; } }
            continue;
        }

        if (lines_rendered >= max_h) break;

        if (b == '\n') {
            if (is_scanning) try out.appendSlice(alloc, C_RESET);
            try out.append(alloc, b);
            lines_rendered += 1; current_line += 1; col = 0;
            is_scanning = (current_line == scan_line);
            if (lines_rendered < max_h) { if (is_scanning) try out.appendSlice(alloc, C_SCAN); if (context == 1) try out.appendSlice(alloc, C_LINK) else try out.appendSlice(alloc, C_TEXT); }
            continue;
        }

        if (col >= max_w) {
            if (is_scanning) try out.appendSlice(alloc, C_RESET);
            try out.append(alloc, '\n');
            lines_rendered += 1; col = 0;
            if (lines_rendered >= max_h) break;
            current_line += 1; is_scanning = (current_line == scan_line);
             if (is_scanning) try out.appendSlice(alloc, C_SCAN);
             if (context == 1) try out.appendSlice(alloc, C_LINK) else try out.appendSlice(alloc, C_TEXT);
        }

        if (b == '<') {
            if (is_scanning) try out.appendSlice(alloc, C_RESET); if (is_scanning) try out.appendSlice(alloc, C_SCAN);
            try out.appendSlice(alloc, C_TAG); try out.append(alloc, b);
            if (i + 1 < data.len) { const n = data[i+1]; if (n == 'a' or n == 'A') context = 1; if (n == '/') context = 0; }
            col += 1; continue;
        } 
        
        if (b == '>') {
            try out.append(alloc, b);
            if (is_scanning) try out.appendSlice(alloc, C_RESET); if (is_scanning) try out.appendSlice(alloc, C_SCAN);
            if (context == 1) try out.appendSlice(alloc, C_LINK) else try out.appendSlice(alloc, C_TEXT);
            col += 1; continue;
        }

        col += 1; try out.append(alloc, b);
    }
    
    try out.appendSlice(alloc, C_RESET);
    try rawPrint(out.items);
}

fn drawOverlay(philote: *PhiloteEngine) !void {
    try rawPrint("\n" ++ C_LINK ++ "+--------------------------------+" ++ C_RESET ++ "\n");
    try rawPrint(C_LINK ++ "|        SYSTEM OVERLAY          |" ++ C_RESET ++ "\n");
    try rawPrint(C_LINK ++ "+--------------------------------+" ++ C_RESET ++ "\n");
    try rawPrint("| " ++ C_TEXT ++ "ARROWS" ++ C_RESET ++ "    Move Scanner         |\n");
    try rawPrint("| " ++ C_TEXT ++ "L/R" ++ C_RESET ++ "       Jump to Links        |\n");
    try rawPrint("| " ++ C_TEXT ++ "@://x+/-" ++ C_RESET ++ "  Raw / Sentinel       |\n");
    try rawPrint("| " ++ C_TEXT ++ "@://z+/-" ++ C_RESET ++ "  Change Scope         |\n");
    try rawPrint("| " ++ C_TEXT ++ "salud" ++ C_RESET ++ "     Halt Engine          |\n");
    try rawPrint(C_LINK ++ "+--------------------------------+" ++ C_RESET ++ "\n");
    var i: usize = 0; while (i < 5 and i < philote.nodes.items.len) : (i += 1) {
         try rawPrintf("  " ++ C_LINK ++ "#{d}" ++ C_RESET ++ " {s}\n", .{i+1, philote.nodes.items[i].url});
    }
}

fn connect(allocator: std.mem.Allocator, url: []const u8, child_ptr: *?process.Child, fds: *[2]posix.pollfd) !void {
    if (child_ptr.*) |*c| { _ = c.kill() catch {}; _ = c.wait() catch {}; child_ptr.* = null; fds[1].fd = -1; }
    const argv = [_][]const u8{ "curl", "-s", "-L", "-i", "-k", "-N", url };
    var child = process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch { return; };
    child_ptr.* = child;
    if (child.stdout) |stdout_pipe| fds[1].fd = stdout_pipe.handle;
}
