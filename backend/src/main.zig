const std = @import("std");
const c = @cImport({
    @cInclude("mqtt.h");
    @cInclude("netdb.h");
});
const log = std.log;
const posix = std.posix;

const zig_router = @import("zig-router");

const zap = @import("zap");
const Mustache = zap.Mustache;

const sqlite = @import("sqlite");

fn index(r: zap.Request) void {
    const template = @embedFile("template.html");
    var m = Mustache.fromData(template) catch return;
    defer m.deinit();
    const ret = m.build(.{});
    if (ret.str()) |str| {
        r.sendBody(str) catch {};
    } else {
        r.sendBody("Not found") catch {};
    }
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

    var db = try sqlite.Db.init(.{
        .mode = .{ .File = "data.db" },
        .open_flags = .{ .write = true, .create = true },
    });
    defer db.deinit();

    const mqtt_socket = try std.net.tcpConnectToHost(
        gpa.allocator(),
        "ec2-13-60-15-160.eu-north-1.compute.amazonaws.com",
        // "127.0.0.1",
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

    client.publish_response_callback_state = &db;

    _ = c.mqtt_connect(&client, "backend", null, null, 0, null, null, c.MQTT_CONNECT_CLEAN_SESSION, 400);
    if (client.@"error" != c.MQTT_OK) return error.MqttConnectFailure;
    defer _ = c.mqtt_disconnect(&client);

    inline for (2..7) |i| {
        _ = c.mqtt_subscribe(&client, std.fmt.comptimePrint("stations/M{d}", .{i}), 0);
    }

    const thread = try std.Thread.spawn(.{}, mqttSync, .{&client});
    defer {
        running.store(false, .unordered);
        thread.join();
    }

    const sql_init =
        \\CREATE TABLE IF NOT EXISTS datapoints (
        \\  station_id TEXT,
        \\  callsign TEXT,
        \\  longitude REAL,
        \\  latitude REAL,
        \\  time TEXT,
        \\  atmospheric_pressure REAL,
        \\  wind_direction REAL,
        \\  wind_speed REAL,
        \\  gust REAL REAL,
        \\  wave_height REAL,
        \\  wave_period REAL,
        \\  mean_wave_direction REAL,
        \\  hmax REAL,
        \\  air_temperature REAL,
        \\  dew_point REAL,
        \\  sea_temperature REAL,
        \\  salinity REAL,
        \\  relative_humidity REAL,
        \\  spr_tp REAL,
        \\  th_tp REAL,
        \\  tp REAL,
        \\  qc_flag INTEGER
        \\);
    ;

    var diags: sqlite.Diagnostics = .{};
    errdefer |err| if (err == error.SQLiteError) log.err("{}\n", .{diags});

    var init_stmt = try db.prepareWithDiags(sql_init, .{ .diags = &diags });
    defer init_stmt.deinit();

    try init_stmt.exec(.{}, .{});

    var router = zap.Router.init(gpa.allocator(), .{});
    defer router.deinit();

    try router.handle_func_unbound("/", &index);

    var listener = zap.HttpListener.init(.{
        .port = 3000,
        .on_request = router.on_request_handler(),
        .log = true,
        .max_clients = 100_000,
        .public_folder = "public",
    });
    try listener.listen();

    log.info("Listening on 0.0.0.0:3000\n", .{});

    // start worker threads
    zap.start(.{
        .threads = 2,
        .workers = 1,
    });
}

const Row = struct {
    id: []const u8,
    callsign: []const u8,
    longitude: f64,
    latitude: f64,
    time: []const u8,
    atmospheric_pressure: f64,
    wind_direction: f64,
    wind_speed: f64,
    gust: f64,
    wave_height: f64,
    wave_period: f64,
    mean_wave_direction: f64,
    hmax: f64,
    air_temperature: f64,
    dew_point: f64,
    sea_temperature: f64,
    salinity: f64,
    relative_humidity: f64,
    spr_tp: f64,
    th_tp: f64,
    tp: f64,
    qc_flag: i64,
};

pub fn publishCallback(ctx: **sqlite.Db, data: *c.mqtt_response_publish) callconv(.C) void {
    const db = ctx.*;

    const message_ptr: [*]const u8 = @ptrCast(data.application_message);
    const message = message_ptr[0..data.application_message_size];

    log.debug("MQTT publish '{s}'\n", .{message});

    const sql_insert =
        \\INSERT INTO datapoints (station_id, callsign, longitude, latitude, time, atmospheric_pressure, wind_direction, wind_speed, gust, wave_height, wave_period, mean_wave_direction, hmax, air_temperature, dew_point, sea_temperature, salinity, relative_humidity, spr_tp, th_tp, tp, qc_flag)
    ++ "VALUES(" ++ ("?, " ** (@typeInfo(Row).Struct.fields.len - 1)) ++ "?);";

    var diags: sqlite.Diagnostics = .{};

    var stmt = db.prepareWithDiags(sql_insert, .{ .diags = &diags }) catch |err| {
        log.err("{}: {}\n", .{ err, diags });
        return;
    };
    defer stmt.deinit();

    // Value lines
    var iter = std.mem.tokenizeScalar(u8, message, ',');

    // Parse comma separated values into an instance of `Row`, to be passed as the bind parameters
    var row: Row = undefined;
    inline for (@typeInfo(Row).Struct.fields) |field| {
        const str = iter.next() orelse return;
        @field(row, field.name) = switch (@typeInfo(field.type)) {
            .Float => std.fmt.parseFloat(field.type, str) catch return,
            .Int => std.fmt.parseInt(field.type, str, 0) catch return,
            else => str,
        };
    }

    stmt.exec(.{}, row) catch return;
    stmt.reset();
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
