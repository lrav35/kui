const std = @import("std");
const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
});

pub const KafkaClient = struct {
    pub fn hello_world(allocator: std.mem.Allocator) ![]const u8 {
        const version = c.rd_kafka_version();
        return std.fmt.allocPrint(allocator, "Hello, World! we are currently using version: {d} of librdkafka", .{version});
    }
};
