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

    pub fn init(client_type: ClientType, group_id: ?[]const u8) !KafkaClient {
        // Config
        const conf = c.rd_kafka_conf_new();
        if (conf == null) return KafkaError.ConfigError;

        // Configure the bootstrap servers
        var errstr: [512]u8 = [_]u8{0} ** 512;
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
        const kafka_type = @as(c_uint, @intCast(switch (client_type) {
            .Producer => c.RD_KAFKA_PRODUCER,
            .Consumer => c.RD_KAFKA_CONSUMER,
        }));

        const kafka_handle = c.rd_kafka_new(kafka_type, conf, &errstr, @as(usize, errstr.len));
        if (kafka_handle == null) {
            return KafkaError.ClientCreationError;
        }

        return KafkaClient{
            .kafka_handle = kafka_handle,
            .client_type = client_type,
        };
    }

    pub fn deinit(self: *KafkaClient) void {
        if (self.kafka_handle) |handle| {
            if (self.client_type == .Consumer) {
                _ = c.rd_kafka_consumer_close(handle);
            }
            _ = c.rd_kafka_destroy(handle);
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
