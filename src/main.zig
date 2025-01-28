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
    watchdog_interval: ?u64 = null,
    last_beat: u64 = 0,
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
            .logger = try log.Logger.init(allocator, .{
                .log_path = "/tmp/axle.log",
                .log_level = .Debug,
            }),
            .running = true,
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
        try self.logger.log(service.name, .Info, "Attempting to start service", .File);

        if (service.state != .Stopped) {
            try self.logger.log(service.name, .Info, "Service is not in a stopped state; current state: {}", .File);
            return;
        }

        const argv = [_][]const u8{service.path};
        var child = std.process.Child.init(&argv, self.allocator);

        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        service.pid = child.id;
        service.state = .Starting;
        try self.logger.log(service.name, .Info, "Service has been started", .File);
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
            const result = std.posix.read(@as(std.posix.fd_t, @intCast(signal_fd)), std.mem.asBytes(&info)[0..@sizeOf(linux.signalfd_siginfo)]);
            if (result) |bytes_read| {
                if (bytes_read == 0) continue;

                switch (info.signo) {
                    linux.SIG.CHLD => try self.handleChildSignal(info),
                    linux.SIG.TERM, linux.SIG.INT => self.running = false,
                    else => {},
                }
            } else |err| {
                if (err == error.WouldBlock) {
                    continue;
                } else {
                    return err;
                }
            }
        }
    }

    pub fn handleChildSignal(self: *InitSystem, info: linux.signalfd_siginfo) !void {
        const pid: i32 = @intCast(info.pid);
        // const exit_status = info.status;

        while (true) {
            var status: u32 = 0;
            const result = linux.waitpid(pid, &status, 0);

            if (result == -1) {
                return error.WaitpidFailed;
            }
            if (result == 0) {
                break;
            } else {
                for (self.services.items) |*service| {
                    if (service.pid) |service_pid| {
                        if (service_pid == result) {
                            service.state = switch (status) {
                                0 => .Stopped,
                                else => .Failed,
                            };
                            switch (service.restart_policy) {
                                .Always => self.startService(service) catch |err| {
                                    std.debug.print("Failed to restart service {s}: {}\n", .{ service.name, err });
                                },
                                .OnFailure => {
                                    if (status != 0) {
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
                break;
            }
        }
    }
};

fn watchdogCheck(self: *InitSystem) !void {
    const now = std.time.timestamp();

    for (self.services.items) |*service| {
        if (service.watchdog_interval) |interval| {
            if (now - service.last_beat > interval and service.state == .Running) {
                std.debug.print("Service {s} missed watchdog, restarting...\n", .{service.name});
                service.state = .Failed;
                try self.startService(service);
            }
        }
    }
}

fn shutdown(self: *InitSystem) !void {
    std.debug.print("Initiating system shutdown...\n", .{});

    for (self.services.items) |*service| {
        if (service.state == .Running) {
            std.debug.print("Stopping service {s}...\n", .{service.name});
            service.state = .Stopped;
        }
    }

    self.running = false;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var init_system = try InitSystem.init(allocator);
    defer init_system.deinit();

    const example_service = Service{
        .name = "hello-world",
        .path = "/workspaces/axle/hello-world.sh",
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
