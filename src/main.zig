const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const linux = os.linux;

const ServiceState = enum {
    Stopped,
    Starting,
    Running,
    Stopping,
    Failed
};

const Service = struct {
    name: []const u8,
    pid: ?linux.pid_t = null,
    state: ServiceState = .Stopped,
    path: []const u8,
    dependencies: []const []const u8 = &.{},
    restart_policy: RestartPolicy = .Never,
};

const RestartPolicy = enum {
    Never,
    OnFailure,
    Always
};

const InitSystem = struct {
    allocator: std.mem.Allocator,
    services: std.ArrayList(Service),
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator) InitSystem {
        return InitSystem{
            .allocator = allocator,
            .services = std.ArrayList(Service).init(allocator),
        };
    }

    pub fn deinit(self: *InitSystem) void {
        self.services.deinit();
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
    _ = self;
    if (service.state != .Stopped) return;

    const pid = blk: {
        const fork_result = linux.fork();
        
        if (fork_result == std.math.maxInt(usize)) {
            return error.SystemCallFailed;
        }
        
        break :blk fork_result;
    };

    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ 
            @ptrCast([*:0]const u8, service.path.ptr), 
            null 
        };

        const envp = [_:null]?[*:0]const u8{null};
        const path = service.path.ptr[0..service.path.len :0];
        _ = linux.execve(
            @ptrCast([*:0]const u8, service.path.ptr), 
            &argv[0], 
            &envp[0]
        );

        linux.exit(1);
    } else {
        service.pid = pid;
        service.state = .Running;
    }
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
        try linux.sigaddset(&sigset, linux.SIG.CHLD);
        try linux.sigaddset(&sigset, linux.SIG.TERM);
        try linux.sigaddset(&sigset, linux.SIG.INT);

        const signal_mask = linux.SIG.BLOCK;
        try linux.sigprocmask(signal_mask, &sigset, null);

        while (self.running) {
            var info: linux.signalfd_siginfo = undefined;
            const signal_fd = try linux.signalfd(-1, &sigset, linux.SFD.NONBLOCK);
            defer os.close(signal_fd);
            
            const bytes_read = try os.read(signal_fd, std.mem.asBytes(&info));
            if (bytes_read == 0) continue;

            switch (info.ssi_signo) {
                linux.SIG.CHLD => try self.handleChildSignal(info),
                linux.SIG.TERM, linux.SIG.INT => self.running = false,
                else => {},
            }
        }
    }

    fn handleChildSignal(self: *InitSystem, info: linux.signalfd_siginfo) !void {
        const pid = info.ssi_pid;
        const exit_status = info.ssi_status;

        for (self.services.items) |*service| {
            if (service.pid) |service_pid| {
                if (service_pid == pid) {
                    service.state = switch (exit_status) {
                        0 => .Stopped,
                        else => .Failed,
                    };
                    
                    switch (service.restart_policy) {
                        .Always => self.startService(service) catch |err| {
                            std.debug.print("Failed to restart service {s}: {}\n", .{service.name, err});
                        },
                        .OnFailure => {
                            if (exit_status != 0) {
                                self.startService(service) catch |err| {
                                    std.debug.print("Failed to restart failed service {s}: {}\n", .{service.name, err});
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
        .name = "example_service",
        .path = "/path/to/service",
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
