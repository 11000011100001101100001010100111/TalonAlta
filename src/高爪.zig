const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const process = std.process;
const fs = std.fs;

// --- CONFIG ---
const VERSION = "v5.2.2 COMPILE-FIX";

// --- ANSI PROTOCOL (@NSIBLE-RED) ---
const C_RESET = "\x1b[0m";
const C_TAG   = "\x1b[31m";   // CRIMSON
const C_LINK  = "\x1b[33m";   // BRASS
const C_TEXT  = "\x1b[37m";   // SILVER
const C_SCAN  = "\x1b[7m";    // INVERSE
const C_BAR   = "\x1b[41;30m";// RED BG / BLACK FG
const C_META  = "\x1b[36m";   // CYAN
const C_LASER = "\x1b[41;37m";// RED BG / WHITE FG

const PhiloteNode = struct { url: []u8, weight: u32 };
const AppMode = enum { VIEWER, MENU, COMMS, CONFIG };

const MailConfig = struct {
    host: []u8,
    user: []u8,
    pass: []u8,
};

// --- SYSCALLS ---
fn rawWrite(fd: i32, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        const written = try posix.write(fd, data[index..]);
        if (written == 0) return;
        index += written;
    }
}
fn rawPrint(data: []const u8) !void { try rawWrite(posix.STDOUT_FILENO, data); }
fn rawPrintf(comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const formatted_slice = try std.fmt.bufPrint(&buf, fmt, args);
    try rawPrint(formatted_slice);
}
fn sysSleep(ms: i32) void { var fds = [0]posix.pollfd{}; _ = posix.poll(&fds, ms) catch {}; }
fn getTermSize() std.posix.winsize {
    var ws = std.posix.winsize{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    _ = std.os.linux.ioctl(posix.STDOUT_FILENO, 0x5413, @intFromPtr(&ws));
    if (ws.row == 0) ws.row = 24; if (ws.col == 0) ws.col = 80;
    return ws;
}

// --- PHILOTE ---
const PhiloteEngine = struct {
    nodes: std.ArrayListUnmanaged(PhiloteNode) = .{},
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) PhiloteEngine { return .{ .allocator = allocator }; }
    pub fn deinit(self: *PhiloteEngine) void { for (self.nodes.items) |n| self.allocator.free(n.url); self.nodes.deinit(self.allocator); }
    pub fn load(self: *PhiloteEngine) !void {
        const file = fs.cwd().openFile("philote.db", .{}) catch return; defer file.close();
        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); defer self.allocator.free(content);
        var iter = mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            var parts = mem.splitScalar(u8, line, '|');
            const u = parts.next() orelse continue; const w = parts.next() orelse "0";
            try self.nodes.append(self.allocator, .{ .url = try self.allocator.dupe(u8, u), .weight = std.fmt.parseInt(u32, w, 10) catch 0 });
        }
    }
    pub fn hit(self: *PhiloteEngine, target: []const u8) !void {
        for (self.nodes.items) |*n| { if (mem.eql(u8, n.url, target)) { n.weight += 1; return; } }
        try self.nodes.append(self.allocator, .{ .url = try self.allocator.dupe(u8, target), .weight = 1 });
    }
};

// --- STATE ---
const AppState = struct {
    scope: i8 = 1, url: []const u8 = "STANDBY", status: []const u8 = "IDLE",
    mode: AppMode = .VIEWER,
    input_buffer: [256]u8 = undefined, input_len: usize = 0,
    scroll_y: usize = 0, scan_line: usize = 0, raw_mode: bool = false, bytes_rx: usize = 0,
    history: std.ArrayListUnmanaged([]u8) = .{},
    mail_conf: MailConfig = .{ .host = "", .user = "", .pass = "" },
    config_step: u8 = 0,
    dirty: bool = true,
};

// --- UTILS ---
fn urlEncode(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    for (input) |c| { if (c == ' ') { try out.appendSlice(alloc, "%20"); } else { try out.append(alloc, c); } }
    return out.toOwnedSlice(alloc);
}
fn saveLoot(alloc: std.mem.Allocator, name: []const u8, data: []const u8, is_bin: bool) !void {
    fs.cwd().makeDir("loot") catch {};
    const ext = if (is_bin) ".bin" else ".txt";
    const filename = try std.fmt.allocPrint(alloc, "loot/{s}{s}", .{name, ext}); defer alloc.free(filename);
    const file = try fs.cwd().createFile(filename, .{}); defer file.close();
    try file.writeAll(data);
}
fn saveConfig(alloc: std.mem.Allocator, conf: *MailConfig) !void {
    const data = try std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{conf.host, conf.user, conf.pass}); defer alloc.free(data);
    const file = try fs.cwd().createFile("mail.conf", .{}); defer file.close();
    try file.writeAll(data);
}
fn loadConfig(alloc: std.mem.Allocator, conf: *MailConfig) !bool {
    const file = fs.cwd().openFile("mail.conf", .{}) catch return false; defer file.close();
    const content = try file.readToEndAlloc(alloc, 4096); 
    var iter = mem.splitScalar(u8, content, '\n');
    conf.host = try alloc.dupe(u8, iter.next() orelse return false);
    conf.user = try alloc.dupe(u8, iter.next() orelse return false);
    conf.pass = try alloc.dupe(u8, iter.next() orelse return false);
    return true;
}

// --- MAIN ---
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const stdin_fd = posix.STDIN_FILENO;
    const original_termios = try posix.tcgetattr(stdin_fd);
    var raw = original_termios; raw.lflag.ECHO = false; raw.lflag.ICANON = false; raw.lflag.ISIG = false;
    try posix.tcsetattr(stdin_fd, .NOW, raw); defer posix.tcsetattr(stdin_fd, .NOW, original_termios) catch {};

    try rawPrint("\x1b[2J\x1b[H"); 
    try rawPrint(C_LASER ++ " @NSIBLE SECURE UPLINK " ++ C_RESET ++ "\n");
    sysSleep(200);

    var state = AppState{};
    var philote = PhiloteEngine.init(allocator); defer philote.deinit(); try philote.load();
    if (!try loadConfig(allocator, &state.mail_conf)) { state.mode = .CONFIG; }

    var child_ptr: ?process.Child = null;
    var fds = [2]posix.pollfd{ .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 }, .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 } };
    
    var raw_cache = std.ArrayListUnmanaged(u8){}; defer raw_cache.deinit(allocator);
    var display_cache = std.ArrayListUnmanaged(u8){}; defer display_cache.deinit(allocator);

    const args = try process.argsAlloc(allocator); defer process.argsFree(allocator, args);
    if (args.len > 1) {
        const payload = mem.trim(u8, args[1], "'");
        if (mem.startsWith(u8, payload, "@://")) {
            const target = payload[4..]; 
            try navigate(allocator, &state, target, &child_ptr, &fds, &raw_cache, &philote, false);
        }
    }

    const LOGO = [_][]const u8{ "      .---.      ", "     /     \\     ", "    |  (O)  |    ", "     \\     /     ", "      '---'      ", "", " @NSIBLE SECURE UPLINK", " [|||||||||||||] 100%" };
    var splash_idx: usize = 0; var mask_active = (state.mode != .CONFIG);

    while (true) {
        _ = try posix.poll(&fds, 40);

        if (fds[1].fd != -1 and (fds[1].revents & posix.POLL.IN != 0)) {
            var net_buf: [4096]u8 = undefined;
            const bytes = try posix.read(fds[1].fd, &net_buf);
            if (bytes > 0) {
                try raw_cache.appendSlice(allocator, net_buf[0..bytes]); state.bytes_rx += bytes;
                try computeDisplayView(allocator, raw_cache.items, &display_cache, &state);
                state.dirty = true;
            } else { fds[1].fd = -1; state.status = "IDLE"; state.dirty = true; }
        }

        if (mask_active) {
            try rawPrint("\x1b[2J\x1b[H\n");
            for (LOGO, 0..) |line, row| {
                if (row == splash_idx) { try rawPrint(C_LASER); try rawPrint(line); try rawPrint("\x1b[K" ++ C_RESET ++ "\n"); }
                else if (row < splash_idx) { try rawPrint(C_TAG); try rawPrint(line); try rawPrint(C_RESET ++ "\n"); }
                else { try rawPrint("\n"); }
            }
            try rawPrint("\n  " ++ C_TEXT ++ "Initializing Core..." ++ C_RESET);
            if (splash_idx < LOGO.len) splash_idx += 1 else if (state.bytes_rx > 0 or fds[1].fd == -1 or mem.eql(u8, state.url, "STANDBY")) mask_active = false;
            continue;
        }

        if (state.dirty) {
            try renderFrame(&state, display_cache.items, &philote);
            state.dirty = false;
        }

        if (fds[0].revents & posix.POLL.IN != 0) {
            var buf: [128]u8 = undefined; const n = try posix.read(stdin_fd, &buf); if (n == 0) break;
            var i: usize = 0;
            while (i < n) {
                const char = buf[i];
                state.dirty = true;

                if (char == '\t') { 
                    if (state.mode != .CONFIG) { state.mode = switch (state.mode) { .VIEWER => .MENU, .MENU => .COMMS, .COMMS => .VIEWER, else => .VIEWER }; }
                    i += 1; continue; 
                }

                if (state.mode == .CONFIG) {
                    if (char == '\n' or char == '\r') {
                        const input = state.input_buffer[0..state.input_len];
                        if (state.config_step == 0) state.mail_conf.host = try allocator.dupe(u8, input)
                        else if (state.config_step == 1) state.mail_conf.user = try allocator.dupe(u8, input)
                        else if (state.config_step == 2) {
                            state.mail_conf.pass = try allocator.dupe(u8, input);
                            try saveConfig(allocator, &state.mail_conf);
                            state.mode = .VIEWER; 
                        }
                        if (state.mode == .CONFIG) state.config_step += 1;
                        state.input_len = 0;
                    } else if (char >= 32 and char <= 126) { if (state.input_len < 255) { state.input_buffer[state.input_len] = char; state.input_len += 1; } }
                    else if (char == 127 and state.input_len > 0) state.input_len -= 1;
                    i += 1; continue;
                }

                if (char == 27 and i + 2 < n and buf[i+1] == '[') {
                    const code = buf[i+2]; const ws = getTermSize(); const vh = if (ws.row > 5) ws.row - 5 else 5;
                    if (code == 'A' and state.scan_line > 0) { state.scan_line -= 1; if (state.scan_line < state.scroll_y) state.scroll_y = state.scan_line; }
                    if (code == 'B') { state.scan_line += 1; if (state.scan_line >= state.scroll_y + vh) state.scroll_y = state.scan_line - vh + 1; }
                    if (i + 3 < n and buf[i+3] == '~') { 
                        if (code == '5') { if (state.scan_line >= vh) state.scan_line -= vh else state.scan_line = 0; if (state.scan_line < state.scroll_y) state.scroll_y = state.scan_line; }
                        if (code == '6') { state.scan_line += vh; if (state.scan_line >= state.scroll_y + vh) state.scroll_y = state.scan_line - vh + 1; }
                        i += 4; continue;
                    }
                    i += 3; continue;
                }
                if (char == 127) { if (state.input_len > 0) state.input_len -= 1; i += 1; continue; }
                if (char == '\n' or char == '\r') {
                    const cmd = state.input_buffer[0..state.input_len];
                    if (state.input_len == 0) {
                        const url = extractUrlFromLine(allocator, display_cache.items, state.scan_line);
                        if (url) |u| try navigate(allocator, &state, u, &child_ptr, &fds, &raw_cache, &philote, true);
                    } else {
                        if (mem.eql(u8, cmd, "salud")) return;
                        if (mem.eql(u8, cmd, "@://z+")) { if (state.scope < 2) { state.scope += 1; try computeDisplayView(allocator, raw_cache.items, &display_cache, &state); } }
                        else if (mem.eql(u8, cmd, "@://z-")) { if (state.scope > -1) { state.scope -= 1; try computeDisplayView(allocator, raw_cache.items, &display_cache, &state); } }
                        else if (mem.eql(u8, cmd, "@://x+")) { state.raw_mode = true; try computeDisplayView(allocator, raw_cache.items, &display_cache, &state); }
                        else if (mem.eql(u8, cmd, "@://x-")) { state.raw_mode = false; try computeDisplayView(allocator, raw_cache.items, &display_cache, &state); }
                        else if (mem.eql(u8, cmd, "@://reload")) { try navigate(allocator, &state, state.url, &child_ptr, &fds, &raw_cache, &philote, false); }
                        else if (mem.startsWith(u8, cmd, "@://save ")) { saveLoot(allocator, cmd[9..], raw_cache.items, state.scope == -1) catch {}; state.status = "SECURED"; }
                        else if (mem.startsWith(u8, cmd, "@://w ")) {
                            const enc = try urlEncode(allocator, cmd[6..]); const t = try std.fmt.allocPrint(allocator, "https://en.wikipedia.org/wiki/Special:Search?search={s}", .{enc});
                            try navigate(allocator, &state, t, &child_ptr, &fds, &raw_cache, &philote, true);
                        }
                        else if (mem.startsWith(u8, cmd, "@://? ")) {
                            const enc = try urlEncode(allocator, cmd[6..]); const t = try std.fmt.allocPrint(allocator, "https://lite.duckduckgo.com/lite/?q={s}", .{enc});
                            try navigate(allocator, &state, t, &child_ptr, &fds, &raw_cache, &philote, true);
                        }
                        else if (mem.startsWith(u8, cmd, "@://")) try navigate(allocator, &state, cmd[4..], &child_ptr, &fds, &raw_cache, &philote, true);
                        state.input_len = 0;
                    }
                } else if (char >= 32 and char <= 126) { if (state.input_len < 255) { state.input_buffer[state.input_len] = char; state.input_len += 1; } }
                i += 1;
            }
        }
    }
}

// --- LOGIC ---
fn connect(alloc: std.mem.Allocator, url: []const u8, child_ptr: *?process.Child, fds: *[2]posix.pollfd) !void {
    if (child_ptr.*) |*c| { _ = c.kill() catch {}; _ = c.wait() catch {}; child_ptr.* = null; fds[1].fd = -1; }
    const argv = [_][]const u8{ "curl", "-s", "-L", "-i", "-k", "-N", url };
    var child = process.Child.init(&argv, alloc); child.stdout_behavior = .Pipe; child.stderr_behavior = .Ignore;
    try child.spawn(); child_ptr.* = child; if (child.stdout) |p| fds[1].fd = p.handle;
}
fn navigate(alloc: std.mem.Allocator, state: *AppState, target: []const u8, child_ptr: *?process.Child, fds: *[2]posix.pollfd, cache: *std.ArrayListUnmanaged(u8), philote: *PhiloteEngine, push: bool) !void {
    state.url = try alloc.dupe(u8, target); state.status = "FETCHING"; state.bytes_rx = 0; state.scroll_y = 0; state.scan_line = 0; state.dirty = true;
    cache.clearRetainingCapacity(); // NUKE OLD DATA
    if (push) try state.history.append(alloc, try alloc.dupe(u8, target));
    try philote.hit(target); try connect(alloc, target, child_ptr, fds);
}
fn computeDisplayView(alloc: std.mem.Allocator, raw: []const u8, display: *std.ArrayListUnmanaged(u8), state: *AppState) !void {
    display.clearRetainingCapacity(); if (raw.len == 0) return;
    var split_idx: usize = 0; if (mem.indexOf(u8, raw, "\r\n\r\n")) |idx| split_idx = idx + 4 else if (mem.indexOf(u8, raw, "\n\n")) |idx| split_idx = idx + 2;
    if (state.scope == -1) {
        var i: usize = 0; while (i < raw.len) {
            const chunk = raw[i .. if (i+16 > raw.len) raw.len else i+16];
            const line = try std.fmt.allocPrint(alloc, "{x:0>8} | ", .{i}); try display.appendSlice(alloc, line);
            for (chunk) |b| { const hex = try std.fmt.allocPrint(alloc, "{x:0>2} ", .{b}); try display.appendSlice(alloc, hex); }
            try display.append(alloc, '\n'); i += 16;
        }
    } else {
        const body = if (state.scope == 1 and split_idx > 0) raw[split_idx..] else raw;
        if (state.raw_mode) { try display.appendSlice(alloc, body); return; }
        
        // SENTINEL ENGINE (Restored)
        var i: usize = 0;
        while (i < body.len) {
            if (body[i] == '<') {
                try display.appendSlice(alloc, C_TAG); try display.append(alloc, '<');
                i += 1;
                while (i < body.len and body[i] != '>') { try display.append(alloc, body[i]); i += 1; }
                if (i < body.len) { try display.append(alloc, '>'); i += 1; }
                try display.appendSlice(alloc, C_TEXT); 
            } else { try display.append(alloc, body[i]); i += 1; }
        }
    }
}
fn extractUrlFromLine(alloc: std.mem.Allocator, data: []const u8, target_line: usize) ?[]u8 {
    var cur: usize = 0; var iter = mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| : (cur += 1) {
        if (cur == target_line) {
            if (mem.indexOf(u8, line, "http")) |s| { var e = s; while (e<line.len and line[e]!=' ' and line[e]!='"') : (e+=1){} return alloc.dupe(u8, line[s..e]) catch null; }
            if (mem.indexOf(u8, line, "href=\"/")) |s| { var e = s+6; while (e<line.len and line[e]!='"' and line[e]!=' '): (e+=1){} const r = line[s+6..e]; return std.fmt.allocPrint(alloc, "https://en.wikipedia.org{s}", .{r}) catch null; }
        }
    }
    return null;
}

fn renderFrame(state: *AppState, content: []const u8, philote: *PhiloteEngine) !void {
    const ws = getTermSize(); const vh = if (ws.row > 5) ws.row - 5 else 5;
    try rawPrint("\x1b[2J\x1b[H"); try rawPrintf(C_BAR ++ " :: 高爪 TALON ALTA " ++ VERSION ++ " :: \x1b[K" ++ C_RESET ++ "\n", .{});

    if (state.mode == .CONFIG) {
        try rawPrint("\n" ++ C_LINK ++ " +--- INITIAL SETUP REQUIRED ---+\n" ++ C_RESET);
        const steps = [_][]const u8{"IMAP Host", "Email Address", "Password"};
        try rawPrintf(" | {s}: {s}\n", .{steps[state.config_step], state.input_buffer[0..state.input_len]});
        try rawPrint(C_LINK ++ " +------------------------------+\n" ++ C_RESET);
        return;
    }

    if (state.mode == .MENU) {
        try rawPrint("\n" ++ C_LINK ++ " +--- SYSTEM MENU ---+\n" ++ C_RESET);
        try rawPrint("| " ++ C_TEXT ++ "@://w [query]" ++ C_RESET ++ "  Wiki Search          |\n");
        try rawPrint("| " ++ C_TEXT ++ "@://? [query]" ++ C_RESET ++ "  DDG Search           |\n");
        try rawPrint("| " ++ C_TEXT ++ "@://save [nm]" ++ C_RESET ++ "  Archival (Scribe)    |\n");
        try rawPrint("| " ++ C_TEXT ++ "z+/-" ++ C_RESET ++ "           Scope (Hex/Meta/Web) |\n");
        try rawPrint("| " ++ C_TEXT ++ "x+/-" ++ C_RESET ++ "           Raw/Sentinel Mode    |\n");
        try rawPrint(C_LINK ++ " +----------------------+\n" ++ C_RESET);
        for (philote.nodes.items, 0..) |n, i| { if (i<5) try rawPrintf("  " ++ C_LINK ++ "#{d}" ++ C_RESET ++ " {s}\n", .{i+1, n.url}); }
    } else if (state.mode == .COMMS) {
        try rawPrint("\n" ++ C_LINK ++ " +--- COMMS LINK (DISCONNECTED) ---+\n" ++ C_RESET);
        try rawPrintf(" | HOST: {s}\n", .{state.mail_conf.host});
        try rawPrintf(" | USER: {s}\n", .{state.mail_conf.user});
        try rawPrint(" | STATUS: OFFLINE (Skeleton Mode)\n");
        try rawPrint(" | \n | Usage: This module will connect to your\n | local Maildir partition. Use sync tools\n | to fetch data to ./mail/\n");
        try rawPrint(C_LINK ++ " +---------------------------------+\n" ++ C_RESET);
    } else {
        var cur: usize = 0; var drawn: usize = 0; var iter = mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| : (cur += 1) {
            if (cur < state.scroll_y) continue; if (drawn >= vh) break;
            var trimmed = line; if (mem.endsWith(u8, trimmed, "\r")) trimmed = trimmed[0..trimmed.len-1];
            try rawPrint(C_RESET); if (cur == state.scan_line) try rawPrint(C_SCAN);
            try rawPrint(C_TEXT); try rawPrint(trimmed); try rawPrint(C_RESET ++ "\x1b[K\n"); drawn += 1;
        }
    }
    const m_str = switch (state.mode) { .VIEWER => "VIEWER", .MENU => "MENU", .COMMS => "COMMS", .CONFIG => "SETUP" };
    try rawPrintf("\x1b[{d};H" ++ C_BAR ++ " MODE: {s} | L:{d} | RX:{d} \x1b[K" ++ C_RESET ++ "\n> ", .{ws.row - 1, m_str, state.scan_line, state.bytes_rx});
    if (state.input_len > 0) try rawPrint(state.input_buffer[0..state.input_len]);
}
