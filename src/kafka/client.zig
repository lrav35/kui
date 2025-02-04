const std = @import("std");
const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
});

pub const TimestampType = enum {
    CREATE,
    LOG_APPEND,
    N_A,
};

pub const KafkaMessage = struct {
    payload: ?[]const u8,
    key: ?[]const u8,
    topic: []const u8,
    partition: i32,
    offset: i64,
    timestamp: []u8,
    timestampType: TimestampType,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const KafkaMessage) void {
        self.allocator.free(self.timestamp);
    }
};

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

    pub fn subscribe(self: *KafkaClient, topics: []const []const u8) !void {
        if (self.client_type != .Consumer) {
            return KafkaError.ConsumerError;
        }

        const topic_list = c.rd_kafka_topic_partition_list_new(@intCast(topics.len));
        defer c.rd_kafka_topic_partition_list_destroy(topic_list);

        for (topics) |topic| {
            _ = c.rd_kafka_topic_partition_list_add(topic_list, topic.ptr, -1);
        }

        const err = c.rd_kafka_subscribe(self.kafka_handle.?, topic_list);
        if (err != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            return KafkaError.SubscriptionError;
        }
    }

    fn formatTimestamp(timestamp: i64, buffer: []u8) ![]const u8 {
        // std.debug.print("Raw Kafka timestamp: {d}\n", .{timestamp});

        const seconds = @divFloor(timestamp, 1000);

        // std.debug.print("Seconds since epoch: {d}\n", .{seconds});
        const datetime = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
        const epoch_day = datetime.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const month = month_day.month.numeric();
        const day_secs = datetime.getDaySeconds();
        const hours = day_secs.getHoursIntoDay();
        const minutesInHour = day_secs.getMinutesIntoHour();
        const secondsInMinute = day_secs.getSecondsIntoMinute();

        // std.debug.print("year: {d}\n", .{year_day.year});
        //
        // std.debug.print("month: {d}\n", .{month});
        //
        // std.debug.print("day: {d}\n", .{month_day.day_index});
        //
        // std.debug.print("hour: {d}\n", .{hours});
        //
        // std.debug.print("mins: {d}\n", .{minutesInHour});
        //
        // std.debug.print("seconds: {d}\n", .{secondsInMinute});

        // Format as: "YYYY-MM-DD HH:MM:SS"
        return try std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year_day.year,
            month,
            month_day.day_index,
            hours,
            minutesInHour,
            secondsInMinute,
        });
    }

    pub fn consumeMessage(self: *KafkaClient, allocator: std.mem.Allocator, timeout_ms: i32) !?KafkaMessage {
        if (self.client_type != .Consumer) {
            return KafkaError.ConsumerError;
        }

        const message = c.rd_kafka_consumer_poll(self.kafka_handle.?, timeout_ms);
        if (message == null) {
            return null;
        }
        defer c.rd_kafka_message_destroy(message);

        if (message.*.err != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            std.debug.print("Consumer error: {s}\n", .{c.rd_kafka_err2str(message.*.err)});
            return null;
        }

        const topic_handle = message.*.rkt;
        const topic_name = c.rd_kafka_topic_name(topic_handle);

        var timestamp_type: c.rd_kafka_timestamp_type_t = c.RD_KAFKA_TIMESTAMP_NOT_AVAILABLE;
        const timestamp = c.rd_kafka_message_timestamp(message, &timestamp_type);

        const ts_type = switch (timestamp_type) {
            c.RD_KAFKA_TIMESTAMP_CREATE_TIME => TimestampType.CREATE,
            c.RD_KAFKA_TIMESTAMP_LOG_APPEND_TIME => TimestampType.LOG_APPEND,
            else => TimestampType.N_A,
        };

        var time_buffer: [32]u8 = .{0} ** 32;
        const formatted_time = try formatTimestamp(timestamp, &time_buffer);

        const timestamp_copy = try allocator.alloc(u8, formatted_time.len);
        @memcpy(timestamp_copy, formatted_time);

        const msg = KafkaMessage{
            .payload = if (message.*.payload != null)
                @as([*]const u8, @ptrCast(message.*.payload))[0..message.*.len]
            else
                null,
            .key = if (message.*.key != null)
                @as([*]const u8, @ptrCast(message.*.key))[0..message.*.key_len]
            else
                null,
            .topic = std.mem.span(topic_name),
            .partition = message.*.partition,
            .offset = message.*.offset,
            .timestamp = timestamp_copy,
            .timestampType = ts_type,
            .allocator = allocator,
        };
        return msg;
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
