const std = @import("std");
const builtin = @import("builtin");
const os = std.os;

pub const LogLevel = enum(u8) {
    Emergency = 0, // System is unusable
    Alert = 1, // Action must be taken immediately
    Critical = 2, // Critical conditions
    Error = 3, // Error conditions
    Warning = 4, // Warning conditions
    Notice = 5, // Normal but significant condition
    Info = 6, // Informational messages
    Debug = 7, // Debug-level messages
    Trace = 8, // Most verbose logging

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .Emergency => "EMERG",
            .Alert => "ALERT",
            .Critical => "CRIT",
            .Error => "ERROR",
            .Warning => "WARN",
            .Notice => "NOTICE",
            .Info => "INFO",
            .Debug => "DEBUG",
            .Trace => "TRACE",
        };
    }
};

pub const LogTarget = enum { Console, File, Journal, Network };

pub const LogEntry = struct {
    timestamp: i64,
    service_name: []const u8,
    level: LogLevel,
    message: []const u8,
    pid: ?os.linux.pid_t = null,
    target: LogTarget = .Console,
};

pub const LoggerConfig = struct {
    max_log_size: usize = 10 * 1024 * 1024, // 10MB default
    log_path: []const u8 = "/var/log/init.log",
    log_level: LogLevel = .Info,
    rotate_files: u8 = 5,
};

pub const Logger = struct {
    allocator: std.mem.Allocator,
    config: LoggerConfig,
    log_file: ?std.fs.File = null,
    log_entries: std.ArrayList(LogEntry),

    pub fn init(allocator: std.mem.Allocator, config: LoggerConfig) !Logger {
        const log_file = try std.fs.cwd().createFile(config.log_path, .{
            .mode = .read_write,
            .truncate = false,
        });

        return Logger{
            .allocator = allocator,
            .config = config,
            .log_file = log_file,
            .log_entries = std.ArrayList(LogEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Logger) void {
        if (self.log_file) |file| {
            file.close();
        }
        self.log_entries.deinit();
    }

    pub fn log(self: *Logger, service_name: []const u8, level: LogLevel, message: []const u8, target: LogTarget) !void {
        // Skip logging if message level is higher than configured level
        if (@intFromEnum(level) > @intFromEnum(self.config.log_level)) return;

        const entry = LogEntry{
            .timestamp = std.time.timestamp(),
            .service_name = service_name,
            .level = level,
            .message = message,
            .pid = os.linux.getpid(),
            .target = target,
        };

        try self.log_entries.append(entry);
        try self.writeLog(entry);
    }

    fn writeLog(self: *Logger, entry: LogEntry) !void {
        const log_line = try std.fmt.allocPrint(self.allocator, "[{d}] {s}/{s}: {s}\n", .{ entry.timestamp, entry.service_name, entry.level.toString(), entry.message });
        defer self.allocator.free(log_line);

        switch (entry.target) {
            .Console => std.debug.print("{s}", .{log_line}),
            .File => {
                if (self.log_file) |file| {
                    _ = try file.write(log_line);
                }
            },
            .Journal => {
                // Placeholder for systemd journal logging
                // Would require linking to libsystemd
            },
            .Network => {
                // Placeholder for network logging
            },
        }

        // Optional: Rotate logs if file exceeds max size
        try self.rotateLogsIfNeeded();
    }

    fn rotateLogsIfNeeded(self: *Logger) !void {
        if (self.log_file) |file| {
            const file_size = try file.getEndPos();
            if (file_size > self.config.max_log_size) {
                try self.rotateLogFiles();
            }
        }
    }

    fn rotateLogFiles(self: *Logger) !void {
        const log_path = self.config.log_path;

        // Close current log file
        if (self.log_file) |file| {
            file.close();
        }

        // Rotate log files using copy and delete
        var i = self.config.rotate_files;
        while (i > 0) : (i -= 1) {
            const old_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ log_path, i });
            defer self.allocator.free(old_path);

            const new_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ log_path, i + 1 });
            defer self.allocator.free(new_path);

            // Use copyFile instead of renameFile
            std.fs.cwd().copyFile(std.fs.cwd(), old_path, std.fs.cwd(), new_path, .{}) catch {};

            // Delete old file after copying
            std.fs.cwd().deleteFile(old_path) catch {};
        }
        self.log_file = try std.fs.cwd().createFile(log_path, .{
            .mode = .read_write,
            .truncate = false,
        });
    }
};

// Example usage
test "logger functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var logger = try Logger.init(allocator, .{
        .log_path = "/tmp/init.log",
        .log_level = .Debug,
    });
    defer logger.deinit();

    try logger.log("systemd", .Info, "System starting", .Console);
    try logger.log("networkd", .Warning, "Network configuration failed", .File);
}
