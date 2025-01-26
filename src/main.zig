const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const linux = os.linux;
const log = @import("log.zig");

const ServiceState = enum { Stopped, Starting, Running, Stopping, Failed };

const Service = struct {
    name: []const u8,
    pid: ?linux.pid_t = null,
    state: ServiceState = .Stopped,
    path: []const u8,
    dependencies: []const []const u8 = &.{},
    restart_policy: RestartPolicy = .Never,
};

const RestartPolicy = enum { Never, OnFailure, Always };

const InitSystem = struct {
    allocator: std.mem.Allocator,
    services: std.ArrayList(Service),
    running: bool = true,
    logger: log.Logger,

    pub fn init(allocator: std.mem.Allocator) !InitSystem {
        return InitSystem{
            .allocator = allocator,
            .services = std.ArrayList(Service).init(allocator),
            .logger = try log.Logger.init(allocator, .{}),
        };
    }

    pub fn deinit(self: *InitSystem) void {
        self.services.deinit();
        self.logger.deinit();
    }

    pub fn addService(self: *InitSystem, service: Service) !void {
        try self.services.append(service);
    }

    pub fn startServices(self: *InitSystem) !void {
        for (self.services.items) |*service| {
            try self.startService(service);
        }
    }

    fn startService(self: *InitSystem, service: *Service) !void {
        try self.logger.log(service.name, .Info, "Starting service", .File);

        if (service.state != .Stopped) return;

        if (service.state == .Running) {
            try self.logger.log(service.name, .Info, "Service started successfully", .Console);
        } else {
            try self.logger.log(service.name, .Error, "Service failed to start", .File);
        }

        const argv = [_][]const u8{service.path};
        var child = std.process.Child.init(&argv, self.allocator);

        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        const term = try child.wait();

        service.pid = child.id;
        service.state = switch (term) {
            .Exited => |code| if (code == 0) .Running else .Failed,
            else => .Failed,
        };
    }

    fn findServiceByName(self: *InitSystem, name: []const u8) ?*Service {
        for (self.services.items) |*service| {
            if (std.mem.eql(u8, service.name, name)) {
                return service;
            }
        }
        return null;
    }

    pub fn handleSignals(self: *InitSystem) !void {
        var sigset = std.mem.zeroes(linux.sigset_t);
        linux.sigaddset(&sigset, linux.SIG.CHLD);
        linux.sigaddset(&sigset, linux.SIG.TERM);
        linux.sigaddset(&sigset, linux.SIG.INT);

        const signal_mask = linux.SIG.BLOCK;
        _ = linux.sigprocmask(signal_mask, &sigset, null);

        while (self.running) {
            var info: linux.signalfd_siginfo = undefined;
            const signal_fd = linux.signalfd(-1, &sigset, linux.SFD.NONBLOCK);
            if (signal_fd == std.math.maxInt(usize)) {
                return error.SignalFDFailed;
            }

            defer std.posix.close(@as(std.posix.fd_t, @intCast(signal_fd)));

            const bytes_read = try std.posix.read(@as(std.posix.fd_t, @intCast(signal_fd)), std.mem.asBytes(&info)[0..@sizeOf(linux.signalfd_siginfo)]);

            if (bytes_read == 0) continue;

            switch (info.signo) {
                linux.SIG.CHLD => try self.handleChildSignal(info),
                linux.SIG.TERM, linux.SIG.INT => self.running = false,
                else => {},
            }
        }
    }

    fn handleChildSignal(self: *InitSystem, info: linux.signalfd_siginfo) !void {
        const pid = info.pid;
        const exit_status = info.status;

        for (self.services.items) |*service| {
            if (service.pid) |service_pid| {
                if (service_pid == pid) {
                    service.state = switch (exit_status) {
                        0 => .Stopped,
                        else => .Failed,
                    };

                    switch (service.restart_policy) {
                        .Always => self.startService(service) catch |err| {
                            std.debug.print("Failed to restart service {s}: {}\n", .{ service.name, err });
                        },
                        .OnFailure => {
                            if (exit_status != 0) {
                                self.startService(service) catch |err| {
                                    std.debug.print("Failed to restart failed service {s}: {}\n", .{ service.name, err });
                                };
                            }
                        },
                        .Never => {},
                    }
                }
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var init_system = InitSystem.init(allocator);
    defer init_system.deinit();

    const example_service = Service{
        .name = "hello-world",
        .path = "/usr/local/bin/hello-world.sh",
        .restart_policy = .OnFailure,
    };

    init_system.addService(example_service) catch |err| {
        std.debug.print("Failed to add service: {}\n", .{err});
        return err;
    };

    init_system.startServices() catch |err| {
        std.debug.print("Failed to start services: {}\n", .{err});
        return err;
    };

    init_system.handleSignals() catch |err| {
        std.debug.print("Error in signal handling: {}\n", .{err});
        return err;
    };
}
