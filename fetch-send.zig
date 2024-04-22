// This is the program run on the Raspberry pi to fetch sensor data and send it to the MQTT broker.
// Currently only fetches data and prints the JSON response to stdout.
// Uses libcurl instead of the http client from the stdlib because the stdlib does not support tls 1.2.
// Requires linking libcurl and libc.
const std = @import("std");
const c = @cImport({
    @cInclude("curl/curl.h");
    @cInclude("curl/easy.h");
});

fn writeData(
    buf: *anyopaque,
    size: usize,
    n: usize,
    writer: *const std.fs.File.Writer,
) callconv(.C) usize {
    const b: [*]u8 = @ptrCast(buf);
    const bytes = b[0 .. size * n];
    writer.writeAll(bytes) catch |err| {
        std.log.err("{}", .{err});
        return 0;
    };
    return size * n;
}

pub fn main() !void {
    const handle = c.curl_easy_init() orelse return error.Failure;
    var res = c.curl_easy_setopt(
        handle,
        c.CURLOPT_URL,
        "https://erddap.marine.ie//erddap/tabledap/IWBNetwork.json?&station_id=%22M5%22&orderByMax(%22time%22)",
    );
    if (res != c.CURLE_OK) return error.SetopFailure;

    res = c.curl_easy_setopt(handle, c.CURLOPT_WRITEFUNCTION, writeData);
    if (res != c.CURLE_OK) return error.Failure;

    const writer = std.io.getStdOut().writer();

    res = c.curl_easy_setopt(handle, c.CURLOPT_WRITEDATA, &writer);
    if (res != c.CURLE_OK) return error.Failure;

    res = c.curl_easy_perform(handle);
    if (res != c.CURLE_OK) return error.Failure;
}
