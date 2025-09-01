const builtin = @import("builtin");
const clap = if (builtin.is_test) struct {} else @import("clap");
const std = @import("std");
const writer = std.io.getStdOut().writer();

/// AppError represents the possible errors that can occur
const AppError = error{
    HTTPStatusNotOK,
    ParseErrorNotFound,
    MissingCommand,
    FileWriteError,
    MissingOutput,
    MissingURL,
};

/// Args represents the command line arguments
const Args = struct {
    url: []const u8,
    output: []const u8,
};

/// GPX represents the root GPX element
const GPX = struct {
    version: []const u8,
    creator: []const u8,
    name: ?[]const u8 = null,
    tracks: []Track,
};

/// Track represents a GPX track
const Track = struct {
    name: ?[]const u8 = null,
    segments: []Segment,
};

/// Segment represents a track segment
const Segment = struct {
    points: []Point,
};

/// Point represents a track point with attributes
const Point = struct {
    latitude: f64,
    longitude: f64,
    elevation: ?f64 = null,
};

fn parseArgs(
    allocator: std.mem.Allocator,
) !Args {
    const params = comptime clap.parseParamsComptime(
        \\-u, --url <str>...     URL of komoot track
        \\-o, --output <str>...  GPX Outputfile
        \\
    );

    var diag = clap.Diagnostic{};
    const res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        // Report useful error and exit.
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };

    // Check for missing arguments
    var missing: []const u8 = "";
    if (res.args.output.len == 0) missing = "--output";
    if (res.args.url.len == 0) missing = if (missing.len > 0) "--output, --url" else "--url";

    if (missing.len > 0) {
        std.debug.print("Error: Missing required argument(s): {s}\n", .{missing});
        return AppError.MissingCommand;
    }

    return .{
        .url = res.args.url[0],
        .output = res.args.output[0],
    };
}

fn get(
    url: []const u8,
    headers: []const std.http.Header,
    client: *std.http.Client,
    allocator: std.mem.Allocator,
) !std.ArrayList(u8) {
    var response_body = std.ArrayList(u8).init(allocator);

    const response = try client.fetch(.{
        .method = .GET,
        .location = .{ .url = url },
        .extra_headers = headers,
        .response_storage = .{ .dynamic = &response_body },
    });

    if (response.status != std.http.Status.ok) {
        try writer.print("Response Status: {d}\n", .{response.status});
        return AppError.HTTPStatusNotOK;
    }

    return response_body;
}

fn parseJsonFromHtml(html: []u8, allocator: std.mem.Allocator) !std.json.Value {
    const start_marker = "kmtBoot.setProps(\"";
    const end_marker = "\");";

    var start_idx = std.mem.indexOf(u8, html, start_marker) orelse return AppError.ParseErrorNotFound;
    start_idx += start_marker.len;

    const end_idx = std.mem.lastIndexOf(u8, html[start_idx..], end_marker) orelse return AppError.ParseErrorNotFound;

    var json = html[start_idx .. start_idx + end_idx];
    json = try std.mem.replaceOwned(u8, allocator, json, "\\\\", "\\");
    json = try std.mem.replaceOwned(u8, allocator, json, "\\\"", "\"");

    return (try std.json.parseFromSlice(std.json.Value, allocator, json, .{})).value;
}

fn gpxFromTrack(track: Track, allocator: std.mem.Allocator) !GPX {
    var tracks = try allocator.alloc(Track, 1);
    tracks[0] = track;

    return GPX{
        .version = "1.1",
        .creator = "zigzag",
        .name = track.name,
        .tracks = tracks,
    };
}

fn writeGPX(gpx: GPX, file_path: []const u8) !void {
    var file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    defer file.close();

    var buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &buf,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<gpx version=\"{s}\" creator=\"{s}\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n" ++
            "  <metadata>\n" ++
            "    <name>{s}</name>\n" ++
            "  </metadata>\n",
        .{ gpx.version, gpx.creator, gpx.name.? },
    );
    try file.writeAll(header);

    for (gpx.tracks) |track_entry| {
        try file.writeAll("  <trk>\n");
        if (track_entry.name) |track_name| {
            const nm = try std.fmt.bufPrint(&buf, "    <name>{s}</name>\n", .{track_name});
            try file.writeAll(nm);
        }

        for (track_entry.segments) |segment| {
            try file.writeAll("    <trkseg>\n");

            for (segment.points) |point| {
                const pt = try std.fmt.bufPrint(&buf, "      <trkpt lat=\"{d:.6}\" lon=\"{d:.6}\">\n", .{ point.latitude, point.longitude });
                try file.writeAll(pt);

                if (point.elevation) |elevation| {
                    const el = try std.fmt.bufPrint(&buf, "        <ele>{d:.1}</ele>\n", .{elevation});
                    try file.writeAll(el);
                }

                try file.writeAll("      </trkpt>\n");
            }

            try file.writeAll("    </trkseg>\n");
        }

        try file.writeAll("  </trk>\n");
    }

    try file.writeAll("</gpx>\n");

    std.debug.print("GPX file written to: {s}\n", .{file_path});
}

fn convertJsonToTrack(json: std.json.Value, allocator: std.mem.Allocator) !Track {
    const track_name_entry = json.object.get("page").?
        .object.get("_embedded").?
        .object.get("tour").?
        .object.get("name");
    const track_name = if (track_name_entry) |n| n.string else "Unknown";

    const coordinate_items = json.object.get("page").?
        .object.get("_embedded").?
        .object.get("tour").?
        .object.get("_embedded").?
        .object.get("coordinates").?
        .object.get("items");

    var points: []Point = undefined;

    if (coordinate_items) |coordinates_json| {
        points = try allocator.alloc(Point, coordinates_json.array.items.len);
        for (coordinates_json.array.items, 0..) |geo_point, i| {
            const altitude_entry = geo_point.object.get("alt");
            const elevation = if (altitude_entry) |alt|
                switch (alt) {
                    .float => alt.float,
                    .integer => @as(f64, @floatFromInt(alt.integer)),
                    else => null,
                }
            else
                null;

            points[i] = Point{
                .latitude = geo_point.object.get("lat").?.float,
                .longitude = geo_point.object.get("lng").?.float,
                .elevation = elevation,
            };
        }
    }

    // Allocate segments to ensure lifetime outlives this function.
    var segments = try allocator.alloc(Segment, 1);
    segments[0] = .{ .points = points };

    return Track{ .name = track_name, .segments = segments };
}

fn fetchTrackHtml(url: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const headers = &[_]std.http.Header{
        .{ .name = "X-Custom-Header", .value = "application" },
        .{ .name = "User-Agent", .value = "Mozilla/5.0" },
    };

    return (try get(url, headers, &client, allocator)).items;
}

fn run(allocator: std.mem.Allocator) !void {
    const args = try parseArgs(allocator);

    const html = try fetchTrackHtml(args.url, allocator);

    const json = try parseJsonFromHtml(html, allocator);

    const track = try convertJsonToTrack(json, allocator);

    const gpx = try gpxFromTrack(track, allocator);
    try writeGPX(gpx, args.output);

    try writer.print("Successfully created GPX file. Track name: {?s}\n", .{track.name});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    run(arena.allocator()) catch |err| {
        // Print to stderr instead of stdout
        std.debug.print("Failed to run: {s}\n", .{@errorName(err)});
        if (std.debug.runtime_safety) {
            // In debug builds, print the stack trace if available
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        }
        std.process.exit(1);
    };
}

const testing = std.testing;

test "writeGPX produces expected XML with points" {
    const allocator = testing.allocator;

    // Prepare sample points and track
    var points = try allocator.alloc(Point, 2);
    defer allocator.free(points);
    points[0] = .{ .latitude = 12.345, .longitude = -98.765 };
    points[1] = .{ .latitude = 0.0, .longitude = 1.0, .elevation = 10.5 };

    var segments = try allocator.alloc(Segment, 1);
    defer allocator.free(segments);
    segments[0] = .{ .points = points };

    const track = Track{ .name = "Test Track", .segments = segments };
    const gpx = try gpxFromTrack(track, allocator);
    defer allocator.free(gpx.tracks);

    // Ensure output directory exists
    std.fs.cwd().makeDir("zig-cache") catch {};
    const out_path = "zig-cache/test-output.gpx";
    // Write and verify file
    try writeGPX(gpx, out_path);

    // Read file back
    const data = try std.fs.cwd().readFileAlloc(allocator, out_path, 2 * 1024 * 1024);
    defer allocator.free(data);
    // Best-effort cleanup
    std.fs.cwd().deleteFile(out_path) catch {};

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
    defer {
        parsed.arena.deinit();
        allocator.destroy(parsed.arena);
    }
    const json_val = parsed.value;

    const track = try convertJsonToTrack(json_val, allocator);
    defer allocator.free(track.segments);
    defer allocator.free(track.segments[0].points);
    try testing.expect(track.name != null);
    try testing.expect(std.mem.eql(u8, track.name.?, "My Tour"));
    try testing.expect(track.segments.len == 1);
    try testing.expect(track.segments[0].points.len == 2);
    try testing.expect(track.segments[0].points[0].elevation != null);
    try testing.expect(track.segments[0].points[1].elevation == null);
    try testing.expect(track.segments[0].points[0].latitude == 1.1);
    try testing.expect(track.segments[0].points[0].longitude == 2.2);
    try testing.expect(track.segments[0].points[1].latitude == 3.3);
    try testing.expect(track.segments[0].points[1].longitude == 4.4);
}

test "sample GPX file exists and has root tags" {
    const allocator = testing.allocator;
    var file = try std.fs.cwd().openFile("miut-115-2023.gpx", .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
    defer allocator.free(data);

    try testing.expect(std.mem.indexOf(u8, data, "<gpx ") != null);
    try testing.expect(std.mem.indexOf(u8, data, "creator=\"komootgpx\"") != null);
    try testing.expect(std.mem.indexOf(u8, data, "</gpx>") != null);
}
