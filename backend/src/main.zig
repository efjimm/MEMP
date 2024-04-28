const std = @import("std");
const c = @cImport({
    @cInclude("mqtt.h");
    @cInclude("netdb.h");
});
const log = std.log;
const posix = std.posix;

const zig_router = @import("zig-router");
const Router = @import("zig-router").Router;
const Route = @import("zig-router").Route;

const zap = @import("zap");
const Mustache = zap.Mustache;
const Sockets = zap.WebSockets;

const sqlite = @import("sqlite");

const SocketHandler = Sockets.Handler(SocketContext);

const SocketContext = struct {
    value: u32 = 0,
    subscribe_args: SocketHandler.SubscribeArgs,
    settings: SocketHandler.WebSocketSettings,
};

fn onUpgrade(r: zap.Request, target_protocol: []const u8) void {
    if (!std.mem.eql(u8, target_protocol, "websocket")) {
        log.warn("Received illegal protocol {s}", .{target_protocol});
        r.setStatus(.bad_request);
        r.sendBody("400 - BAD REQUEST") catch {};
        return;
    }

    const context = gpa.allocator().create(SocketContext) catch |err| {
        log.err("Could not create socket context: {}", .{err});
        return;
    };
    context.* = .{
        .subscribe_args = .{
            .channel = "sensor-data",
            .force_text = true,
            .context = context,
        },
        .settings = .{
            .on_open = onOpenWebsocket,
            .on_close = onCloseWebsocket,
            .context = context,
        },
    };

    SocketHandler.upgrade(r.h, &context.settings) catch |err| {
        log.err("Could not upgrade connection: {}", .{err});
        return;
    };
}

fn onOpenWebsocket(context: ?*SocketContext, handle: Sockets.WsHandle) void {
    const ctx = context orelse return;

    _ = SocketHandler.subscribe(handle, &ctx.subscribe_args) catch |err| {
        std.log.err("Error opening websocket: {}", .{err});
        return;
    };

    log.info("Opened websocket", .{});
}

fn onCloseWebsocket(context: ?*SocketContext, _: isize) void {
    if (context) |ctx| {
        gpa.allocator().destroy(ctx);
    }
    log.info("Closing websocket", .{});
}

fn sendSensorData() void {
    var r = std.rand.DefaultPrng.init(1_000_001);
    const rand = r.random();

    while (running.load(.unordered)) {
        const value = rand.int(u8);

        var buf: [21]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;

        SocketHandler.publish(.{ .channel = "sensor-data", .message = slice });

        std.time.sleep(std.time.ns_per_ms * 500);
    }
}

const App = struct {
    fn index(r: zap.Request) void {
        const template = @embedFile("template.html");
        var m = Mustache.fromData(template) catch return;
        defer m.deinit();
        const ret = m.build(.{
            .name = "friend",
        });
        if (ret.str()) |str| {
            r.sendBody(str) catch {};
        } else {
            r.sendBody("Not found") catch {};
        }
    }
};

fn onRequest(r: zap.Request) void {
    const method_str = r.method orelse {
        log.warn("Empty method string", .{});
        return;
    };

    const router = Router(.{}, .{
        Route(.GET, "/", App.index, .{}),
    });

    const request: router.Request = .{
        .method = @enumFromInt(zig_router.Method.parse(method_str)),
        .path = r.path orelse "/",
    };

    router.match(gpa.allocator(), request, .{r}) catch |err| {
        log.err("Match {}", .{err});
    };
}

var gpa: std.heap.GeneralPurposeAllocator(.{
    .thread_safe = true,
}) = .{};

var running = std.atomic.Value(bool).init(true);

pub fn main() !void {
    defer _ = gpa.deinit();

    try posix.sigaction(posix.SIG.INT, &.{
        .handler = .{ .handler = &sigintHandler },
        .mask = .{0} ** 32,
        .flags = 0,
    }, null);

    const mqtt_socket = try std.net.tcpConnectToHost(
        gpa.allocator(),
        // "ec2-13-60-15-160.eu-north-1.compute.amazonaws.com",
        "127.0.0.1",
        1883,
    );
    defer mqtt_socket.close();
    _ = try posix.fcntl(mqtt_socket.handle, posix.F.SETFL, std.os.linux.SOCK.NONBLOCK);

    var send_buf: [4096]u8 = undefined;
    var recv_buf: [4096]u8 = undefined;

    var client: c.mqtt_client = .{};

    _ = c.mqtt_init(
        &client,
        mqtt_socket.handle,
        &send_buf,
        send_buf.len,
        &recv_buf,
        recv_buf.len,
        @ptrCast(&publishCallback),
    );

    _ = c.mqtt_connect(&client, "backend", null, null, 0, null, null, c.MQTT_CONNECT_CLEAN_SESSION, 400);
    if (client.@"error" != c.MQTT_OK) return error.MqttConnectFailure;

    inline for (2..7) |i| {
        _ = c.mqtt_subscribe(&client, std.fmt.comptimePrint("stations/M{d}", .{i}), 0);
    }

    const thread = try std.Thread.spawn(.{}, mqttSync, .{&client});
    defer thread.join();

    var db = try sqlite.Db.init(.{
        .mode = .{ .File = "data.db" },
        .open_flags = .{ .write = true, .create = true },
    });
    defer db.deinit();

    // var listener = zap.HttpListener.init(.{
    //     .port = 3000,
    //     .on_request = onRequest,
    //     .on_upgrade = onUpgrade,
    //     .log = true,
    //     .max_clients = 100_000,
    //     .public_folder = "public",
    // });
    // try listener.listen();

    // std.debug.print("Listening on 0.0.0.0:3000\n", .{});

    // const sender = try std.Thread.spawn(.{}, sendSensorData, .{});

    // // start worker threads
    // zap.start(.{
    //     .threads = 2,
    //     .workers = 1,
    // });

    // running.store(false, .unordered);

    // sender.join();
}

pub fn publishCallback(_: *anyopaque, data: *c.mqtt_response_publish) callconv(.C) void {
    const topic_ptr: [*]const u8 = @ptrCast(data.topic_name);
    const topic = topic_ptr[0..data.topic_name_size];

    const message_ptr: [*]const u8 = @ptrCast(data.application_message);
    const message = message_ptr[0..data.application_message_size];

    std.debug.print("{s}: {s}\n", .{ topic, message });
}

fn mqttSync(client: *c.mqtt_client) void {
    while (running.load(.unordered)) {
        _ = c.mqtt_sync(client);
        std.time.sleep(std.time.ns_per_ms * 200);
    }
}

pub fn sigintHandler(_: c_int) callconv(.C) void {
    running.store(false, .unordered);
}
