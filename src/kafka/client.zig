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
