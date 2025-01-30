okay so i have a file called client.zig and I would like import it and run the functions in my main.zig file. I will paste the contents of both files here. can you help me with this? how do i import and handle memory, etc

main.zig:


const std = @import("std");
const vaxis = @import("vaxis");
const kafka = @import("kafka/client.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    std.debug.print("hello world", .{});
}

client.zig:


const std = @import("std");
const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
});

pub const KafkaError = error{
    ConfigError,
    ClientCreationError,
    MetadataError,
};

pub const KafkaClient = struct {
    kafka_handle: ?*c.rd_kafka_t,

    // Initialize the client
    pub fn init() !KafkaClient {
        // Create Kafka configuration
        const conf = c.rd_kafka_conf_new();
        if (conf == null) return KafkaError.ConfigError;

        // Configure the bootstrap servers
        var errstr: [512]u8 = undefined;
        const bootstrap_servers = "localhost:9092";
        if (c.rd_kafka_conf_set(conf, "bootstrap.servers", bootstrap_servers, &errstr, errstr.len) != c.RD_KAFKA_CONF_OK) {
            c.rd_kafka_conf_destroy(conf);
            return KafkaError.ConfigError;
        }

        // Create the Kafka handle
        const kafka_handle = c.rd_kafka_new(c.RD_KAFKA_PRODUCER, conf, &errstr, errstr.len);
        if (kafka_handle == null) {
            return KafkaError.ClientCreationError;
        }

        return KafkaClient{
            .kafka_handle = kafka_handle,
        };
    }

    // Clean up resources
    pub fn deinit(self: *KafkaClient) void {
        if (self.kafka_handle) |handle| {
            c.rd_kafka_destroy(handle);
        }
    }

    // Get metadata for all topics
    pub fn getMetadata(self: *KafkaClient, timeout_ms: i32) !void {
        var metadata: ?*c.rd_kafka_metadata_t = null;
        const err = c.rd_kafka_metadata(self.kafka_handle.?, 1, // all_topics
            null, // only_topic
            &metadata, timeout_ms);

        if (err != 0) {
            return KafkaError.MetadataError;
        }

        defer c.rd_kafka_metadata_destroy(metadata);

        // Print metadata information
        if (metadata) |md| {
            std.debug.print("Metadata for {d} brokers:\n", .{md.broker_cnt});

            var i: usize = 0;
            while (i < md.broker_cnt) : (i += 1) {
                const broker = md.brokers[i];
                std.debug.print("  Broker {d}: {s}:{d}\n", .{
                    broker.id,
                    broker.host,
                    broker.port,
                });
            }

            std.debug.print("\nMetadata for {d} topics:\n", .{md.topic_cnt});
            i = 0;
            while (i < md.topic_cnt) : (i += 1) {
                const topic = md.topics[i];
                std.debug.print("  Topic: {s}\n", .{topic.topic});
            }
        }
    }
};

'll help you import and use the KafkaClient from client.zig in your main.zig. Here's how you can do it:

1. First, make sure both files are in the same directory or adjust the import path accordingly.

2. Here's how you should modify your main.zig:

```zig
const std = @import("std");
const vaxis = @import("vaxis");
const kafka = @import("client.zig");  // Import the local file directly

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a Kafka client
    var client = try kafka.KafkaClient.init();
    defer client.deinit();  // Clean up resources when done

    // Print initial message
    std.debug.print("Kafka client initialized\n", .{});

    // Try to get metadata
    try client.getMetadata(5000);  // 5000ms timeout
}
```

Key points:

1. Change the import statement to `@import("client.zig")` to import your local file.

. Initialize the KafkaClient using `try kafka.KafkaClient.init()`

3. Use `defer client.deinit()` to ensure cleanup when the function exits

4. The GeneralPurposeAllocator is already correctly set up in your code

Make sure you have:
- librdkafka installed on your system
- The correct path to the rdkafka.h header file in your build configuration

To build and run this, you'll need to set up your build.zig file to handle the C dependencies. Here's a basic build.zig example:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "your-program",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Link with librdkafka
    exe.linkSystemLibrary("rdkafka");
    exe.addIncludePath(.{ .path = "/usr/include" });  // Adjust this path as needed
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

To build and run:
```bash
zig build run
```

Remember to handle errors appropriately and adjust paths and configurations according to your specific setup.


Okay, now I would like to modify my client.zig to also have the capability to act as a consumer and print out topic info and mesages. can you help me do that?

Here's an enhanced version of your client.zig that adds consumer functionality:

```zig
const std = @import("std");
const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
});

pub const KafkaError = error{
    ConfigError,
    ClientCreationError,
    MetadataError,
    SubscriptionError,
    ConsumerError,
    TopicPartitionError,
};

pub const ClientType = enum {
    Producer,
    Consumer,
};

pub const KafkaClient = struct {
    kafka_handle: ?*c.rd_kafka_t,
    client_type: ClientType,

    // Initialize the client
    pub fn init(client_type: ClientType, group_id: ?[]const u8) !KafkaClient {
        // Create Kafka configuration
        const conf = c.rd_kafka_conf_new();
        if (conf == null) return KafkaError.ConfigError;

        // Configure the bootstrap servers
        var errstr: [512]u8 = undefined;
        const bootstrap_servers = "localhost:9092";
        if (c.rd_kafka_conf_set(conf, "bootstrap.servers", bootstrap_servers, &errstr, errstr.len) != c.RD_KAFKA_CONF_OK) {
            c.rd_kafka_conf_destroy(conf);
            return KafkaError.ConfigError;
        }

        // If it's a consumer, set the group.id
        if (client_type == .Consumer) {
            if (group_id) |id| {
                if (c.rd_kafka_conf_set(conf, "group.id", id.ptr, &errstr, errstr.len) != c.RD_KAFKA_CONF_OK) {
                    c.rd_kafka_conf_destroy(conf);
                    return KafkaError.ConfigError;
                }
            }
            // Set auto.offset.reset to "earliest"
            if (c.rd_kafka_conf_set(conf, "auto.offset.reset", "earliest", &errstr, errstr.len) != c.RD_KAFKA_CONF_OK) {
                c.rd_kafka_conf_destroy(conf);
                return KafkaError.ConfigError;
            }
        }

        // Create the Kafka handle
        const kafka_type = switch (client_type) {
            .Producer => c.RD_KAFKA_PRODUCER,
            .Consumer => c.RD_KAFKA_CONSUMER,
        };
        
        const kafka_handle = c.rd_kafka_new(kafka_type, conf, &errstr, errstr.len);
        if (kafka_handle == null) {
            return KafkaError.ClientCreationError;
        }

        return KafkaClient{
            .kafka_handle = kafka_handle,
            .client_type = client_type,
        };
    }

    // Clean up resources
    pub fn deinit(self: *KafkaClient) void {
        if (self.kafka_handle) |handle| {
            if (self.client_type == .Consumer) {
                c.rd_kafka_consumer_close(handle);
            }
            c.rd_kafka_destroy(handle);
        }
    }

    // Subscribe to topics (Consumer only)
    pub fn subscribe(self: *KafkaClient, topics: []const []const u8) !void {
        if (self.client_type != .Consumer) {
            return KafkaError.ConsumerError;
        }

        var topic_list = c.rd_kafka_topic_partition_list_new(@intCast(topics.len));
        defer c.rd_kafka_topic_partition_list_destroy(topic_list);

        for (topics) |topic| {
            _ = c.rd_kafka_topic_partition_list_add(topic_list, topic.ptr, -1);
        }

        const err = c.rd_kafka_subscribe(self.kafka_handle.?, topic_list);
        if (err != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            return KafkaError.SubscriptionError;
        }
    }

    // Consume messages (Consumer only)
    pub fn consumeMessage(self: *KafkaClient, timeout_ms: i32) !?[]const u8 {
        if (self.client_type != .Consumer) {
            return KafkaError.ConsumerError;
        }

        const message = c.rd_kafka_consumer_poll(self.kafka_handle.?, timeout_ms);
        if (message == null) {
            return null;
        }
        defer c.rd_kafka_message_destroy(message);

        if (message.?.err != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            std.debug.print("Consumer error: {s}\n", .{c.rd_kafka_err2str(message.?.err)});
            return null;
        }

        const payload = message.?.payload;
        const len = message.?.len;
        
        if (payload == null or len == 0) {
            return null;
        }

        return std.mem.span(@as([*:0]const u8, @ptrCast(payload))[0..len]);
    }

    // Get metadata for all topics
    pub fn getMetadata(self: *KafkaClient, timeout_ms: i32) !void {
        var metadata: ?*c.rd_kafka_metadata_t = null;
        const err = c.rd_kafka_metadata(self.kafka_handle.?, 1, // all_topics
            null, // only_topic
            &metadata, timeout_ms);

        if (err != 0) {
            return KafkaError.MetadataError;
        }

        defer c.rd_kafka_metadata_destroy(metadata);

        // Print metadata information
        if (metadata) |md| {
            std.debug.print("Metadata for {d} brokers:\n", .{md.broker_cnt});

            var i: usize = 0;
            while (i < md.broker_cnt) : (i += 1) {
                const broker = md.brokers[i];
                std.debug.print("  Broker {d}: {s}:{d}\n", .{
                    broker.id,
                    broker.host,
                    broker.port,
                });
            }

            std.debug.print("\nMetadata for {d} topics:\n", .{md.topic_cnt});
            i = 0;
            while (i < md.topic_cnt) : (i += 1) {
                const topic = md.topics[i];
                std.debug.print("  Topic: {s}\n", .{topic.topic});
            }
        }
    }
};
```

And here's an example of how to use it in your main.zig:

```zig
const std = @import("std");
const kafka = @import("client.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a Kafka consumer
    var consumer = try kafka.KafkaClient.init(.Consumer, "my-group-id");
    defer consumer.deinit();

    std.debug.print("Kafka consumer initialized\n", .{});

    // Get metadata
    try consumer.getMetadata(5000);

    // Subscribe to topics
    const topics = [_][]const u8{"test-topic"};
    try consumer.subscribe(&topics);
    std.debug.print("Subscribed to topics\n", .{});

    // Consume messages in a loop
    while (true) {
        if (try consumer.consumeMessage(1000)) |msg| {
            std.debug.print("Received message: {s}\n", .{msg});
        }
    }
}
```

Key changes and additions:

1. Added a `ClientType` enum to distinguish between producers and consumers
2. Modified the `init` function to accept a client type and optional group ID
3. Added a `subscribe` function for consumers to subscribe to topics
4. Added a `consumeMessage` function to poll for and receive messages
5. Added proper cleanup in `deinit` for consumers
6. Added new error types for consumer operations

To use this:

1. Create a consumer with a group ID:
```zig
var consumer = try kafka.KafkaClient.init(.Consumer, "my-group-id");
```

2. Subscribe to topics:
```zig
const topics = [_][]const u8{"topic1", "topic2"};
try consumer.subscribe(&topics);
```

3. Consume messages in a loop:
```zig
while (true) {
    if (try consumer.consumeMessage(1000)) |msg| {
        std.debug.print("Received message: {s}\n", .{msg});
    }
}
```

Remember to:
- Handle errors appropriately
- Set up proper configuration in your build.zig
- Have a Kafka broker running at localhost:9092 (or modify the bootstrap servers)
- Create the topics before trying to consume from them

This implementation provides basic consumer functionality. You might want to add more features like:
- Custom configuration options
- Partition assignment
- Offset management
- Message key handling
- Headers handling
- Batch processing
