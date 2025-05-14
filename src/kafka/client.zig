const std = @import("std");
const c = @cImport({
    @cInclude("rdkafka.h");
});
const vaxis = @import("vaxis");
const main = @import("root");
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
    TopicNameTooLong,
};

pub const ClientType = enum {
    Producer,
    Consumer,
};

pub const KafkaClient = struct {
    kafka_handle: ?*c.rd_kafka_t,
    client_type: ClientType,
    group_state: ?*ConsumerGroupState,

    fn setConfig(conf: ?*c.rd_kafka_conf_t, key: [*:0]const u8, value: [*:0]const u8, errstr: *[512]u8) !void {
        if (c.rd_kafka_conf_set(conf, key, value, errstr, errstr.len) != c.RD_KAFKA_CONF_OK) {
            c.rd_kafka_conf_destroy(conf);
            return KafkaError.ConfigError;
        }
    }

    pub fn init(allocator: std.mem.Allocator, client_type: ClientType, group_id: ?[]const u8) !KafkaClient {
        // Config
        const conf = c.rd_kafka_conf_new();
        if (conf == null) return KafkaError.ConfigError;

        // Configure the bootstrap servers
        var errstr: [512]u8 = [_]u8{0} ** 512;
        try setConfig(conf, "bootstrap.servers", "localhost:9092", &errstr);

        // If it's a consumer, set the group.id and auto.offset.reset
        if (client_type == .Consumer) {
            if (group_id) |id| {
                // Need to convert to null-terminated string
                const id_z = try allocator.dupeZ(u8, id);
                defer allocator.free(id_z);
                try setConfig(conf, "group.id", id_z, &errstr);
            }
            try setConfig(conf, "auto.offset.reset", "earliest", &errstr);
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

    pub fn subscribe(self: *KafkaClient, topics: []TopicInfo) !void {
        if (self.client_type != .Consumer) {
            return KafkaError.ConsumerError;
        }

        const topic_list = c.rd_kafka_topic_partition_list_new(@intCast(topics.len));
        defer c.rd_kafka_topic_partition_list_destroy(topic_list);

        for (topics) |*topic| {
            _ = c.rd_kafka_topic_partition_list_add(topic_list, topic.name.ptr, -1);
        }

        const err = c.rd_kafka_subscribe(self.kafka_handle.?, topic_list);
        if (err != c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            return KafkaError.SubscriptionError;
        }

        var subscription: ?*c.rd_kafka_topic_partition_list_t = null;
        const metadata_result = c.rd_kafka_subscription(self.kafka_handle, &subscription);
        if (metadata_result == c.RD_KAFKA_RESP_ERR_NO_ERROR) {
            defer c.rd_kafka_topic_partition_list_destroy(subscription);
        }
    }

    fn formatTimestamp(timestamp: i64, buffer: []u8) ![]const u8 {
        const seconds = @divFloor(timestamp, 1000);
        const ts = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
        const epoch_day = ts.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = ts.getDaySeconds();

        return try std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            year_day.year,
            @as(u8, @intCast(month_day.month.numeric())),
            month_day.day_index,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
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
            if (message.*.rkt != null) {
                std.debug.print("Failed topic: {s}\n", .{c.rd_kafka_topic_name(message.*.rkt)});
            }
            return null;
        }

        const topic_name = c.rd_kafka_topic_name(message.*.rkt);

        var timestamp_type: c.rd_kafka_timestamp_type_t = c.RD_KAFKA_TIMESTAMP_NOT_AVAILABLE;
        const timestamp = c.rd_kafka_message_timestamp(message, &timestamp_type);

        const ts_type = switch (timestamp_type) {
            c.RD_KAFKA_TIMESTAMP_CREATE_TIME => TimestampType.CREATE,
            c.RD_KAFKA_TIMESTAMP_LOG_APPEND_TIME => TimestampType.LOG_APPEND,
            else => TimestampType.N_A,
        };

        var time_buffer: [32]u8 = .{0} ** 32;
        const formatted_time = try formatTimestamp(timestamp, &time_buffer);
        const timestamp_copy = try allocator.dupe(u8, formatted_time);

        return KafkaMessage{
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
    }

    pub fn getTopics(self: *KafkaClient, allocator: std.mem.Allocator, timeout_ms: i32) ![]TopicInfo {
        var metadata: ?*c.rd_kafka_metadata_t = null;
        defer if (metadata != null) c.rd_kafka_metadata_destroy(metadata);

        const err = c.rd_kafka_metadata(self.kafka_handle.?, 1, null, @ptrCast(&metadata), timeout_ms);

        if (err != 0) return KafkaError.MetadataError;
        if (metadata == null or metadata.?.topic_cnt < 0) return &[_]TopicInfo{};

        var topics = std.ArrayList(TopicInfo).init(allocator);
        defer topics.deinit();

        errdefer for (topics.items) |*topic| topic.deinit();

        const total_topics = @as(usize, @intCast(metadata.?.topic_cnt));
        try topics.ensureTotalCapacity(total_topics);

        for (0..total_topics) |i| {
            const topic = metadata.?.topics[i];
            const topic_name = if (topic.topic) |name| std.mem.span(name) else continue;

            // Skip internal topics
            if (std.mem.startsWith(u8, topic_name, "__")) continue;

            const partition_count = @max(0, topic.partition_cnt);
            try topics.append(try TopicInfo.init(allocator, topic_name, @intCast(partition_count)));
        }

        return topics.toOwnedSlice();
    }
};

pub const KafkaContext = struct {
    should_quit: std.atomic.Value(bool),
    loop: *vaxis.Loop(main.Event),
    consumer: *KafkaClient,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        loop: *vaxis.Loop(vaxis.Event),
    ) !KafkaContext {
        var consumer = try KafkaClient.init(allocator, .Consumer, "kui-group-id");
        errdefer consumer.deinit();

        const topics = try consumer.getTopics(allocator, 5000);
        defer {
            for (topics) |*topic| topic.deinit();
            allocator.free(topics);
        }

        try consumer.subscribe(topics);

        return .{
            .should_quit = std.atomic.Value(bool).init(false),
            .loop = loop,
            .consumer = consumer,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.consumer.deinit();
    }
};

pub fn kafkaThread(context: *KafkaContext) !void {
    const time_out_ms = 100;

    while (!context.should_quit.load(.acquire)) {

        // create poll method or use something I alread have
        if (try context.consumer.poll(time_out_ms)) |message| {
            defer message.deinit();

            const msg_copy = try context.allocator.dupe(u8, message.value);
            const id_copy = try context.allocator.dupe(u8, message.id);
            const topic_copy = try context.allocator.dupe(u8, message.topic);

            try context.loop.postEvent(.{
                .consumer_messsage = .{
                    .topic = topic_copy,
                    .msg_id = id_copy,
                    .data = msg_copy,
                },
            });
        }
    }
}

pub const TopicData = struct {
    name: []const u8,
    messages: std.ArrayList(KafkaMessage),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !TopicData {
        return TopicData{
            .name = try allocator.dupe(u8, name),
            .messages = std.ArrayList(KafkaMessage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TopicData) void {
        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit();
        self.allocator.free(self.name);
    }
};

pub const TopicInfo = struct {
    name: [:0]const u8,
    partition_count: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, partition_count: usize) !TopicInfo {
        if (name.len == 0) return error.InvalidName;
        if (name.len >= 255) return error.TopicNameTooLong;
        const name_copy = try allocator.dupeZ(u8, name);
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
        var members = try allocator.alloc(GroupMember, count);
        errdefer allocator.free(members);

        // Initialize all members
        for (0..count) |i| {
            members[i] = try GroupMember.init(allocator, &group.members[i]);
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

        try writer.print(
            \\Group: {s}
            \\  State: {s}
            \\  Protocol Type: {s}
            \\  Protocol: {s}
            \\  Members ({d}):
            \\
        , .{
            self.group_id,
            self.state,
            self.protocol_type,
            self.protocol,
            self.members.len,
        });

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

    const err = c.rd_kafka_list_groups(self.kafka_handle, null, @ptrCast(&list), timeout_ms);
    if (err != 0) return KafkaError.GroupListError;
    if (list == null or list.?.group_cnt < 0) return &[_]GroupInfo{};

    const count = @as(usize, @intCast(list.?.group_cnt));
    if (count == 0) return &[_]GroupInfo{};

    var groups = try allocator.alloc(GroupInfo, count);
    errdefer {
        for (groups) |*group| group.deinit();
        allocator.free(groups);
    }

    for (0..count) |i| {
        groups[i] = try GroupInfo.init(allocator, &list.?.groups[i]);
    }

    return groups;
}
