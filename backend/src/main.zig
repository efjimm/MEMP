const std = @import("std");
const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "1");
    @cInclude("mqtt.h");
    @cInclude("time.h");
});
const log = std.log;
const posix = std.posix;
const assert = std.debug.assert;

const sqlite = @import("sqlite");

var gpa: std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }) = .{};

var running = std.atomic.Value(bool).init(true);

pub fn main() !void {
    defer _ = gpa.deinit();

    var args = std.process.args();
    _ = args.skip();

    // TODO: Write a proper usage string
    const mqtt_broker_host = args.next() orelse return error.NotEnoughArguments;
    const db_filepath = args.next() orelse return error.NotEnoughArguments;

    // Register SIGINT handler
    try posix.sigaction(posix.SIG.INT, &.{
        .handler = .{ .handler = &sigintHandler },
        .mask = .{0} ** 32,
        .flags = 0,
    }, null);

    log.info("opening db", .{});
    var db = try initDb(db_filepath);
    defer db.deinit();

    var recv_buf: [4096]u8 = undefined;
    var send_buf: [4096]u8 = undefined;
    log.info("initializing MQTT client", .{});
    var mqtt = try MqttClient.init(mqtt_broker_host, &db, &send_buf, &recv_buf);
    defer mqtt.deinit();

    log.info("waiting for MQTT publishes", .{});
    while (running.load(.unordered)) {
        mqtt.sync();
        std.time.sleep(std.time.ns_per_s);
    }
}

const Row = struct {
    id: []const u8,
    callsign: []const u8,
    longitude: f64,
    latitude: f64,
    time: i64,
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

/// Called when we receive an MQTT publish on a topic we are subscribed to.
pub fn publishCallback(ctx: **sqlite.Db, data: *c.mqtt_response_publish) callconv(.C) void {
    const db = ctx.*;

    const message_ptr: [*]const u8 = @ptrCast(data.application_message);
    const message = message_ptr[0..data.application_message_size];

    log.debug("MQTT publish '{s}'", .{message});

    const sql_insert =
        \\INSERT INTO datapoints (station_id, callsign, longitude, latitude, time, atmospheric_pressure, wind_direction, wind_speed, gust, wave_height, wave_period, mean_wave_direction, hmax, air_temperature, dew_point, sea_temperature, salinity, relative_humidity, spr_tp, th_tp, tp, qc_flag)
    ++ "VALUES(" ++ ("?, " ** (@typeInfo(Row).Struct.fields.len - 1)) ++ "?);";

    var diags: sqlite.Diagnostics = .{};

    var stmt = db.prepareWithDiags(sql_insert, .{ .diags = &diags }) catch |err| {
        log.err("{}: {}", .{ err, diags });
        return;
    };
    defer stmt.deinit();

    // Value lines
    var iter = std.mem.tokenizeScalar(u8, message, ',');

    // Parse comma separated values into an instance of `Row`, to be passed as the bind parameters
    var row: Row = undefined;
    inline for (@typeInfo(Row).Struct.fields) |field| {
        const str = iter.next() orelse return;

        // Store time as an integer timestamp rather than a string
        if (comptime std.mem.eql(u8, field.name, "time")) {
            var tm: c.tm = .{};
            _ = c.strptime(str.ptr, "%FT%T%z", &tm);
            row.time = c.mktime(&tm);
            continue;
        }

        @field(row, field.name) = switch (@typeInfo(field.type)) {
            .Float => std.fmt.parseFloat(field.type, str) catch return,
            .Int => std.fmt.parseInt(field.type, str, 0) catch return,
            else => str,
        };
    }

    stmt.exec(.{}, row) catch return;
    stmt.reset();
}

/// Handle ctrl-c nicely
pub fn sigintHandler(_: c_int) callconv(.C) void {
    running.store(false, .unordered);
}

/// Initialize the SQLite database
fn initDb(filepath: [:0]const u8) !sqlite.Db {
    var db = try sqlite.Db.init(.{
        .mode = .{ .File = filepath },
        .open_flags = .{ .write = true, .create = true },
    });
    errdefer db.deinit();

    const sql_init =
        \\CREATE TABLE IF NOT EXISTS datapoints (
        \\  station_id TEXT,
        \\  callsign TEXT,
        \\  longitude REAL,
        \\  latitude REAL,
        \\  time INTEGER,
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
        \\  qc_flag INTEGER,
        \\  PRIMARY KEY (station_id, time)
        \\);
    ;

    var diags: sqlite.Diagnostics = .{};
    errdefer |err| if (err == error.SQLiteError) log.err("{}", .{diags});

    var init_stmt = try db.prepareWithDiags(sql_init, .{ .diags = &diags });
    defer init_stmt.deinit();

    try init_stmt.exec(.{}, .{});

    return db;
}

const MqttClient = struct {
    socket: std.net.Stream,
    c_client: c.mqtt_client,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(mqtt_host: []const u8, db: *sqlite.Db, send_buf: []u8, recv_buf: []u8) !MqttClient {
        const mqtt_socket = try std.net.tcpConnectToHost(gpa.allocator(), mqtt_host, 1883);
        errdefer mqtt_socket.close();
        _ = try posix.fcntl(mqtt_socket.handle, posix.F.SETFL, std.os.linux.SOCK.NONBLOCK);

        var client: c.mqtt_client = .{};
        _ = c.mqtt_init(
            &client,
            mqtt_socket.handle,
            send_buf.ptr,
            send_buf.len,
            recv_buf.ptr,
            recv_buf.len,
            @ptrCast(&publishCallback),
        );
        client.publish_response_callback_state = db;

        _ = c.mqtt_connect(&client, "backend", null, null, 0, null, null, c.MQTT_CONNECT_CLEAN_SESSION, 400);
        if (client.@"error" != c.MQTT_OK) return error.MqttConnectFailure;
        errdefer _ = c.mqtt_disconnect(&client);

        // TODO: Listen on only one channel and accept any station id value. This would allow
        //       adding new stations without recompiling this.
        // Subscribe to stations M2-M6
        inline for (2..7) |i| {
            _ = c.mqtt_subscribe(&client, std.fmt.comptimePrint("stations/M{d}", .{i}), 0);
        }

        return .{
            .socket = mqtt_socket,
            .c_client = client,
        };
    }

    pub fn deinit(client: *MqttClient) void {
        _ = c.mqtt_disconnect(&client.c_client);
        client.socket.close();
        client.running.store(false, .unordered);
    }

    fn sync(client: *MqttClient) void {
        _ = c.mqtt_sync(&client.c_client);
    }
};
