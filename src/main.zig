const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const AppError = error{
    HTTPStatusNotOK,
    HelpRequested,
    MissingCommand,
    MissingValue,
    ParseErrorNotFound,
    UnknownArgument,
};

const Args = struct {
    url: []const u8,
    output: []const u8,
};

const GPX = struct {
    version: []const u8,
    creator: []const u8,
    name: ?[]const u8 = null,
    tracks: []Track,
};

const Track = struct {
    name: ?[]const u8 = null,
    segments: []Segment,
};

const Segment = struct {
    points: []Point,
};

const Point = struct {
    latitude: f64,
    longitude: f64,
    elevation: ?f64 = null,
};

fn printUsage(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage: zigzag -u <komoot-url> -o <output.gpx>
        \\
        \\Options:
        \\  -u, --url <url>       URL of Komoot tour
        \\  -o, --output <path>   GPX output file
        \\  -h, --help            Print this help and exit
        \\
    );
}

fn printStderr(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writerStreaming(io, &buffer);
    try stderr_writer.interface.print(fmt, args);
    try stderr_writer.flush();
}

fn printRunError(io: Io, err: anyerror) void {
    switch (err) {
        AppError.MissingCommand => printStderr(io, "Error: missing required --url and/or --output; see --help\n", .{}) catch {},
        AppError.MissingValue => printStderr(io, "Error: option value missing; see --help\n", .{}) catch {},
        AppError.UnknownArgument => printStderr(io, "Error: unknown argument; see --help\n", .{}) catch {},
        else => printStderr(io, "Failed to run: {s}\n", .{@errorName(err)}) catch {},
    }
}

fn valueForOption(argv: []const [:0]const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= argv.len) {
        return AppError.MissingValue;
    }
    return argv[index.*];
}

fn parseArgs(argv: []const [:0]const u8) !Args {
    var url: ?[]const u8 = null;
    var output: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return AppError.HelpRequested;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--url")) {
            url = try valueForOption(argv, &i);
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output = try valueForOption(argv, &i);
        } else {
            return AppError.UnknownArgument;
        }
    }

    if (url == null or output == null) {
        return AppError.MissingCommand;
    }

    return .{
        .url = url.?,
        .output = output.?,
    };
}

fn get(
    io: Io,
    url: []const u8,
    headers: []const std.http.Header,
    client: *std.http.Client,
    allocator: std.mem.Allocator,
) ![]u8 {
    var response_body: std.ArrayList(u8) = .empty;
    var response_writer = Io.Writer.Allocating.fromArrayList(allocator, &response_body);
    defer response_writer.deinit();

    const response = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .extra_headers = headers,
        .response_writer = &response_writer.writer,
    });

    if (response.status != .ok) {
        printStderr(io, "Response Status: {d}\n", .{@intFromEnum(response.status)}) catch {};
        return AppError.HTTPStatusNotOK;
    }

    response_body = response_writer.toArrayList();
    errdefer response_body.deinit(allocator);
    return response_body.toOwnedSlice(allocator);
}

fn parseJsonFromHtml(html: []const u8, allocator: std.mem.Allocator) !std.json.Value {
    const start_marker = "kmtBoot.setProps(\"";
    const end_marker = "\");";

    var start_idx = std.mem.indexOf(u8, html, start_marker) orelse return AppError.ParseErrorNotFound;
    start_idx += start_marker.len;

    const end_idx = std.mem.lastIndexOf(u8, html[start_idx..], end_marker) orelse return AppError.ParseErrorNotFound;

    var json = html[start_idx .. start_idx + end_idx];
    json = try std.mem.replaceOwned(u8, allocator, json, "\\\\", "\\");
    json = try std.mem.replaceOwned(u8, allocator, json, "\\\"", "\"");

    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
}

fn gpxFromTrack(track: Track, allocator: std.mem.Allocator) !GPX {
    const tracks = try allocator.alloc(Track, 1);
    tracks[0] = track;

    return .{
        .version = "1.1",
        .creator = "zigzag",
        .name = track.name,
        .tracks = tracks,
    };
}

fn createOutputFile(io: Io, file_path: []const u8) !Io.File {
    if (std.fs.path.isAbsolute(file_path)) {
        return Io.Dir.createFileAbsolute(io, file_path, .{ .truncate = true });
    }
    return Io.Dir.cwd().createFile(io, file_path, .{ .truncate = true });
}

fn writeGPX(io: Io, gpx: GPX, file_path: []const u8) !void {
    var file = try createOutputFile(io, file_path);
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;

    try writer.print(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<gpx version=\"{s}\" creator=\"{s}\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n" ++
            "  <metadata>\n" ++
            "    <name>{s}</name>\n" ++
            "  </metadata>\n",
        .{ gpx.version, gpx.creator, gpx.name orelse "Unknown" },
    );

    for (gpx.tracks) |track_entry| {
        try writer.writeAll("  <trk>\n");
        if (track_entry.name) |track_name| {
            try writer.print("    <name>{s}</name>\n", .{track_name});
        }

        for (track_entry.segments) |segment| {
            try writer.writeAll("    <trkseg>\n");

            for (segment.points) |point| {
                try writer.print("      <trkpt lat=\"{d:.6}\" lon=\"{d:.6}\">\n", .{ point.latitude, point.longitude });

                if (point.elevation) |elevation| {
                    try writer.print("        <ele>{d:.1}</ele>\n", .{elevation});
                }

                try writer.writeAll("      </trkpt>\n");
            }

            try writer.writeAll("    </trkseg>\n");
        }

        try writer.writeAll("  </trk>\n");
    }

    try writer.writeAll("</gpx>\n");
    try file_writer.flush();
}

fn jsonNumber(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |float| float,
        .integer => |integer| @floatFromInt(integer),
        else => null,
    };
}

fn convertJsonToTrack(json: std.json.Value, allocator: std.mem.Allocator) !Track {
    const tour = json.object.get("page").?
        .object.get("_embedded").?
        .object.get("tour").?;

    const track_name = if (tour.object.get("name")) |name| name.string else "Unknown";
    const coordinate_items = tour.object.get("_embedded").?
        .object.get("coordinates").?
        .object.get("items");

    const coordinates = if (coordinate_items) |items| items.array.items else &[_]std.json.Value{};
    const points = try allocator.alloc(Point, coordinates.len);

    for (coordinates, 0..) |geo_point, i| {
        const elevation = if (geo_point.object.get("alt")) |alt| jsonNumber(alt) else null;
        points[i] = .{
            .latitude = jsonNumber(geo_point.object.get("lat").?).?,
            .longitude = jsonNumber(geo_point.object.get("lng").?).?,
            .elevation = elevation,
        };
    }

    const segments = try allocator.alloc(Segment, 1);
    segments[0] = .{ .points = points };

    return .{ .name = track_name, .segments = segments };
}

fn fetchTrackHtml(io: Io, url: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();

    const headers = &[_]std.http.Header{
        .{ .name = "X-Custom-Header", .value = "application" },
        .{ .name = "User-Agent", .value = "Mozilla/5.0" },
    };

    return try get(io, url, headers, &client, allocator);
}

fn run(io: Io, allocator: std.mem.Allocator, argv: []const [:0]const u8, stdout: *Io.Writer) !void {
    const args = try parseArgs(argv);
    const html = try fetchTrackHtml(io, args.url, allocator);
    const json = try parseJsonFromHtml(html, allocator);
    const track = try convertJsonToTrack(json, allocator);
    const gpx = try gpxFromTrack(track, allocator);

    try writeGPX(io, gpx, args.output);
    try stdout.print("Successfully created GPX file. Track name: {?s}\n", .{track.name});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);

    run(io, arena, argv, &stdout_writer.interface) catch |err| switch (err) {
        AppError.HelpRequested => {
            try printUsage(&stdout_writer.interface);
            return stdout_writer.flush();
        },
        else => {
            printRunError(io, err);
            std.process.exit(1);
        },
    };

    try stdout_writer.flush();
}

test "parseArgs accepts required flags" {
    const argv = [_][:0]const u8{ "zigzag", "-u", "https://example.com/tour", "-o", "out.gpx" };
    const args = try parseArgs(&argv);

    try testing.expectEqualStrings("https://example.com/tour", args.url);
    try testing.expectEqualStrings("out.gpx", args.output);
}

test "parseArgs reports missing required flags" {
    const argv = [_][:0]const u8{"zigzag"};
    try testing.expectError(AppError.MissingCommand, parseArgs(&argv));
}

test "writeGPX produces expected XML with points" {
    const allocator = testing.allocator;

    const points = try allocator.alloc(Point, 2);
    defer allocator.free(points);
    points[0] = .{ .latitude = 12.345, .longitude = -98.765 };
    points[1] = .{ .latitude = 0.0, .longitude = 1.0, .elevation = 10.5 };

    const segments = try allocator.alloc(Segment, 1);
    defer allocator.free(segments);
    segments[0] = .{ .points = points };

    const track = Track{ .name = "Test Track", .segments = segments };
    const gpx = try gpxFromTrack(track, allocator);
    defer allocator.free(gpx.tracks);

    Io.Dir.cwd().createDirPath(testing.io, "zig-cache") catch {};
    const out_path = "zig-cache/test-output.gpx";
    try writeGPX(testing.io, gpx, out_path);

    const data = try Io.Dir.cwd().readFileAlloc(testing.io, out_path, allocator, Io.Limit.limited(2 * 1024 * 1024));
    defer allocator.free(data);
    Io.Dir.cwd().deleteFile(testing.io, out_path) catch {};

    try testing.expect(std.mem.indexOf(u8, data, "<gpx version=\"1.1\" creator=\"zigzag\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "<name>Test Track</name>") != null);
    try testing.expect(std.mem.indexOf(u8, data, "<trkpt lat=\"12.345000\" lon=\"-98.765000\">") != null);
    try testing.expect(std.mem.indexOf(u8, data, "<ele>10.5</ele>") != null);
}

test "convertJsonToTrack from JSON value" {
    const allocator = testing.allocator;
    const json_str =
        "{\"page\":{\"_embedded\":{\"tour\":{\"name\":\"My Tour\",\"_embedded\":{\"coordinates\":{\"items\":[{\"lat\":1.1,\"lng\":2.2,\"alt\":5.0},{\"lat\":3.3,\"lng\":4.4}]}}}}}}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const track = try convertJsonToTrack(parsed.value, allocator);
    defer allocator.free(track.segments);
    defer allocator.free(track.segments[0].points);

    try testing.expect(track.name != null);
    try testing.expectEqualStrings("My Tour", track.name.?);
    try testing.expectEqual(@as(usize, 1), track.segments.len);
    try testing.expectEqual(@as(usize, 2), track.segments[0].points.len);
    try testing.expect(track.segments[0].points[0].elevation != null);
    try testing.expect(track.segments[0].points[1].elevation == null);
    try testing.expectEqual(@as(f64, 1.1), track.segments[0].points[0].latitude);
    try testing.expectEqual(@as(f64, 2.2), track.segments[0].points[0].longitude);
    try testing.expectEqual(@as(f64, 3.3), track.segments[0].points[1].latitude);
    try testing.expectEqual(@as(f64, 4.4), track.segments[0].points[1].longitude);
}

test "sample GPX file exists and has root tags" {
    const allocator = testing.allocator;
    const data = try Io.Dir.cwd().readFileAlloc(testing.io, "miut-115-2023.gpx", allocator, Io.Limit.limited(2 * 1024 * 1024));
    defer allocator.free(data);

    try testing.expect(std.mem.indexOf(u8, data, "<gpx ") != null);
    try testing.expect(std.mem.indexOf(u8, data, "creator=\"komootgpx\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "</gpx>") != null);
}
