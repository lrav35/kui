const std = @import("std");
const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
});
const Mutex = std.Thread.Mutex;

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
    GroupListError,
    InvalidName,
};

pub const ClientType = enum {
    Producer,
    Consumer,
};

pub const KafkaClient = struct {
    kafka_handle: ?*c.rd_kafka_t,
    client_type: ClientType,
    group_state: ?*ConsumerGroupState,

    pub fn init(allocator: std.mem.Allocator, client_type: ClientType, group_id: ?[]const u8) !KafkaClient {
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

        const group_state = try ConsumerGroupState.init(allocator);

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
            .group_state = group_state,
        };
    }

    pub fn deinit(self: *KafkaClient) void {
        if (self.kafka_handle) |handle| {
            if (self.client_type == .Consumer) {
                _ = c.rd_kafka_consumer_close(handle);
            }
            _ = c.rd_kafka_destroy(handle);
        }
        if (self.group_state) |state| {
            state.deinit();
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
        const seconds = @divFloor(timestamp, 1000);

        const datetime = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
        const epoch_day = datetime.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const month = month_day.month.numeric();
        const day_secs = datetime.getDaySeconds();
        const hours = day_secs.getHoursIntoDay();
        const minutesInHour = day_secs.getMinutesIntoHour();
        const secondsInMinute = day_secs.getSecondsIntoMinute();

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

        // // Print metadata information
        // if (metadata) |md| {
        //     std.debug.print("Metadata for {d} brokers:\n", .{md.broker_cnt});
        //
        //     var i: usize = 0;
        //     while (i < md.broker_cnt) : (i += 1) {
        //         const broker = md.brokers[i];
        //         std.debug.print("  Broker {d}: {s}:{d}\n", .{
        //             broker.id,
        //             broker.host,
        //             broker.port,
        //         });
        //     }
        //
        //     std.debug.print("\nMetadata for {d} topics:\n", .{md.topic_cnt});
        //     i = 0;
        //     while (i < md.topic_cnt) : (i += 1) {
        //         const topic = md.topics[i];
        //         std.debug.print("  Topic: {s}\n", .{topic.topic});
        //     }
        // }
    }

    pub fn getTopics(self: *KafkaClient, allocator: std.mem.Allocator, timeout_ms: i32) ![]TopicInfo {
        var metadata: ?*c.rd_kafka_metadata_t = null;
        defer if (metadata != null) c.rd_kafka_metadata_destroy(metadata);

        const err = c.rd_kafka_metadata(self.kafka_handle.?, 1, null, &metadata, timeout_ms);

        if (err != 0) return KafkaError.MetadataError;
        if (metadata == null) return &[_]TopicInfo{};

        if (metadata.?.topic_cnt < 0) return KafkaError.MetadataError;
        const topic_count = @as(usize, @intCast(metadata.?.topic_cnt));

        // Allocate array for topics
        const topics = try allocator.alloc(TopicInfo, topic_count);
        errdefer allocator.free(topics);

        var initialized_count: usize = 0;
        errdefer {
            // Only deinit the successfully initialized topics
            for (topics[0..initialized_count]) |*topic| {
                topic.deinit();
            }
        }

        // Fill topics array
        for (0..topic_count) |i| {
            const topic = metadata.?.topics[i];
            if (topic.topic == null) continue;

            const partition_count = if (topic.partition_cnt >= 0)
                @as(usize, @intCast(topic.partition_cnt))
            else
                0;

            // Ensure topic.topic is valid before creating span
            const topic_name = std.mem.span(topic.topic);
            topics[i] = try TopicInfo.init(allocator, topic_name, partition_count);
            initialized_count += 1;
        }

        return topics;
    }
};

pub const TopicInfo = struct {
    name: []const u8,
    partition_count: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, partition_count: usize) !TopicInfo {
        if (name.len == 0) return error.InvalidName;
        const name_copy = try allocator.dupe(u8, name);
        return TopicInfo{
            .name = name_copy,
            .partition_count = partition_count,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TopicInfo) void {
        self.allocator.free(self.name);
    }
};

const ConsumerGroupState = struct {
    mutex: Mutex,
    is_rebalancing: bool,
    last_rebalance_time: i64,
    current_state: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*ConsumerGroupState {
        const state = try allocator.create(ConsumerGroupState);
        state.* = .{
            .mutex = .{},
            .is_rebalancing = false,
            .last_rebalance_time = 0,
            .current_state = try allocator.dupe(u8, "Unknown"),
            .allocator = allocator,
        };
        return state;
    }

    pub fn deinit(self: *ConsumerGroupState) void {
        self.allocator.free(self.current_state);
        self.allocator.destroy(self);
    }

    pub fn updateState(self: *ConsumerGroupState, new_state: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.allocator.free(self.current_state);
        self.current_state = try self.allocator.dupe(u8, new_state);
    }

    pub fn setRebalancing(self: *ConsumerGroupState, is_rebalancing: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.is_rebalancing = is_rebalancing;
        self.last_rebalance_time = std.time.timestamp();
    }

    pub fn getStatus(self: *ConsumerGroupState) GroupStateInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .is_rebalancing = self.is_rebalancing,
            .last_rebalance_time = self.last_rebalance_time,
            .current_state = self.current_state,
        };
    }
};

const RebalanceContext = struct {
    client: *KafkaClient,
    allocator: std.mem.Allocator,
};

fn rebalanceCallback(
    rk: ?*c.rd_kafka_t,
    err: c.rd_kafka_resp_err_t,
    partitions: ?*c.rd_kafka_topic_partition_list_t,
    user_data: ?*anyopaque,
) callconv(.C) void {
    const context = @as(*RebalanceContext, @ptrCast(@alignCast(user_data)));
    const client = context.client;

    if (client.group_state) |state| {
        switch (err) {
            c.RD_KAFKA_RESP_ERR__ASSIGN_PARTITIONS => {
                state.setRebalancing(true);
                state.updateState("Rebalancing - Assigning") catch {};
                _ = c.rd_kafka_assign(rk, partitions);
                state.setRebalancing(false);
                state.updateState("Stable") catch {};
            },
            c.RD_KAFKA_RESP_ERR__REVOKE_PARTITIONS => {
                state.setRebalancing(true);
                state.updateState("Rebalancing - Revoking") catch {};
                _ = c.rd_kafka_assign(rk, null);
            },
            else => {
                state.updateState("Error") catch {};
                std.debug.print("Rebalancing failed: {s}\n", .{
                    c.rd_kafka_err2str(err),
                });
            },
        }
    }
}

const GroupMember = struct {
    member_id: []const u8,
    client_id: []const u8,
    client_host: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        member: *allowzero const c.rd_kafka_group_member_info,
    ) !GroupMember {
        return GroupMember{
            .member_id = try allocator.dupe(u8, std.mem.span(member.member_id)),
            .client_id = try allocator.dupe(u8, std.mem.span(member.client_id)),
            .client_host = try allocator.dupe(u8, std.mem.span(member.client_host)),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GroupMember) void {
        self.allocator.free(self.member_id);
        self.allocator.free(self.client_id);
        self.allocator.free(self.client_host);
    }

    pub fn format(
        self: GroupMember,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Member: {s} (Client: {s}, Host: {s})", .{
            self.member_id,
            self.client_id,
            self.client_host,
        });
    }
};

const GroupInfo = struct {
    group_id: []const u8,
    state: []const u8,
    protocol_type: []const u8,
    protocol: []const u8,
    members: []GroupMember,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        group: *allowzero const c.rd_kafka_group_info,
    ) !GroupInfo {
        if (group.member_cnt < 0) return KafkaError.GroupListError;
        const count = @as(usize, @intCast(group.member_cnt));
        const members = try allocator.alloc(GroupMember, count);
        errdefer allocator.free(members);

        // Initialize all members
        for (members, 0..count) |*member, i| {
            member.* = try GroupMember.init(allocator, &group.members[i]);
        }

        return GroupInfo{
            .group_id = try allocator.dupe(u8, std.mem.span(group.group)),
            .state = try allocator.dupe(u8, std.mem.span(group.state)),
            .protocol_type = try allocator.dupe(u8, std.mem.span(group.protocol_type)),
            .protocol = try allocator.dupe(u8, std.mem.span(group.protocol)),
            .members = members,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GroupInfo) void {
        for (self.members) |*member| {
            member.deinit();
        }
        self.allocator.free(self.members);
        self.allocator.free(self.group_id);
        self.allocator.free(self.state);
        self.allocator.free(self.protocol_type);
        self.allocator.free(self.protocol);
    }

    pub fn format(
        self: GroupInfo,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Group: {s}\n", .{self.group_id});
        try writer.print("  State: {s}\n", .{self.state});
        try writer.print("  Protocol Type: {s}\n", .{self.protocol_type});
        try writer.print("  Protocol: {s}\n", .{self.protocol});
        try writer.print("  Members ({d}):\n", .{self.members.len});
        for (self.members) |member| {
            try writer.print("    {}\n", .{member});
        }
    }
};

pub const GroupStateInfo = struct {
    is_rebalancing: bool,
    last_rebalance_time: i64,
    current_state: []const u8,
};

pub fn getConsumerGroupInfo(client: *KafkaClient, allocator: std.mem.Allocator, timeout_ms: i32) !struct {
    groups: []GroupInfo,
    state_info: ?GroupStateInfo,
} {
    // Get group info
    const groups = try getGroupInfo(client, allocator, timeout_ms);
    const state_info = if (client.group_state) |state|
        state.getStatus()
    else
        null;

    return .{
        .groups = groups,
        .state_info = state_info,
    };
}

pub fn getGroupInfo(self: *KafkaClient, allocator: std.mem.Allocator, timeout_ms: i32) ![]GroupInfo {
    var list: ?*c.rd_kafka_group_list = null;
    errdefer if (list) |l| c.rd_kafka_group_list_destroy(l);

    const err = c.rd_kafka_list_groups(self.kafka_handle, null, &list, timeout_ms);
    if (err != 0) return KafkaError.GroupListError;
    if (list == null) return &[_]GroupInfo{};

    if (list.?.group_cnt < 0) return KafkaError.GroupListError;
    const count = @as(usize, @intCast(list.?.group_cnt));

    const groups = try allocator.alloc(GroupInfo, count);
    errdefer {
        for (groups) |*group| group.deinit();
        allocator.free(groups);
    }

    for (groups, 0..count) |*group, i| {
        group.* = try GroupInfo.init(allocator, &list.?.groups[i]);
    }

    return groups;
}
