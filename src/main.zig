const std = @import("std");
const vaxis = @import("vaxis");
const kafka = @import("kafka/client.zig");
const vxfw = vaxis.vxfw;
const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
});

const Model = struct {
    allocator: std.mem.Allocator,
    topics: []kafka.TopicData,
    consumer_state: ?kafka.GroupStateInfo,
    selected_topic: usize = 0,
    should_exit: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, topics: []kafka.TopicInfo, state: ?kafka.GroupStateInfo) !*Model {
        const model = try allocator.create(Model);
        errdefer allocator.destroy(model);

        const topic_data = try allocator.alloc(kafka.TopicData, topics.len);
        errdefer allocator.free(topic_data);

        for (topics, 0..) |topic, i| {
            topic_data[i] = try kafka.TopicData.init(allocator, topic.name);
        }

        model.* = .{
            .allocator = allocator,
            .topics = topic_data,
            .consumer_state = state,
            .should_exit = std.atomic.Value(bool).init(false),
        };
        return model;
    }

    pub fn deinit(self: *Model) void {
        if (self.topics.len > 0) {
            for (self.topics) |*topic| {
                topic.deinit();
            }
            self.allocator.free(self.topics);
        }

        self.should_exit.store(true, .seq_cst);
        self.allocator.destroy(self);
    }

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    self.should_exit.store(true, .seq_cst);
                    ctx.quit = true;
                    return;
                }
                if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                    if (self.topics.len > 0) {
                        self.selected_topic = (self.selected_topic + 1) % self.topics.len;
                        ctx.redraw = true;
                    }
                }
                if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                    if (self.topics.len > 0) {
                        if (self.selected_topic == 0) {
                            self.selected_topic = self.topics.len - 1;
                        } else {
                            self.selected_topic -= 1;
                        }
                        ctx.redraw = true;
                    }
                }
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();

        // Create header text
        const header = vxfw.Text{ .text = "Kafka Topics", .style = .{ .bold = true } };
        const header_surf = try header.draw(ctx.withConstraints(
            .{},
            .{ .width = max_size.width, .height = 1 },
        ));

        // Calculate layout dimensions
        const topic_list_width = @min(30, max_size.width / 3); // Adjust these values as needed
        const messages_width = max_size.width - topic_list_width - 1; // -1 for separator
        const content_height = max_size.height - 4; // Space for header and state info

        // Create topic list text
        var topic_text = std.ArrayList(u8).init(ctx.arena);
        for (self.topics, 0..) |topic, i| {
            const prefix = if (i == self.selected_topic) "> " else "  ";
            try topic_text.appendSlice(prefix);
            try topic_text.appendSlice(topic.name);
            try topic_text.append('\n');
        }

        const topics_list = vxfw.RichText{
            .text = &.{
                .{ .text = topic_text.items },
            },
        };

        const topics_surf = try topics_list.draw(ctx.withConstraints(
            .{},
            .{ .width = topic_list_width, .height = content_height },
        ));

        // Create messages text for selected topic
        var messages_text = std.ArrayList(u8).init(ctx.arena);
        if (self.topics.len > 0) {
            const selected_topic = &self.topics[self.selected_topic];
            try std.fmt.format(messages_text.writer(), "Messages for {s}:\n\n", .{selected_topic.name});

            for (selected_topic.messages.items) |msg| {
                try std.fmt.format(messages_text.writer(),
                    \\Offset: {d}
                    \\Key: {?s}
                    \\Payload: {?s}
                    \\-------------------
                    \\
                , .{ msg.offset, msg.key, msg.payload });
            }
        }

        const messages_list = vxfw.RichText{
            .text = &.{
                .{ .text = messages_text.items },
            },
        };

        const messages_surf = try messages_list.draw(ctx.withConstraints(
            .{},
            .{ .width = messages_width, .height = content_height },
        ));

        // Create vertical separator
        var separator = std.ArrayList(u8).init(ctx.arena);
        var i: usize = 0;
        while (i < content_height) : (i += 1) {
            try separator.appendSlice("│");
            try separator.append('\n');
        }

        const separator_text = vxfw.Text{ .text = separator.items };
        const separator_surf = try separator_text.draw(ctx.withConstraints(
            .{},
            .{ .width = 1, .height = content_height },
        ));

        // Create state info text
        var state_text = std.ArrayList(u8).init(ctx.arena);
        try state_text.appendSlice("\nConsumer Group State:\n");
        if (self.consumer_state) |state| {
            try std.fmt.format(state_text.writer(), "Is Rebalancing: {}\nLast Rebalance: {d}\nState: {s}\n", .{
                state.is_rebalancing,
                state.last_rebalance_time,
                state.current_state,
            });
        }

        const state_info = vxfw.Text{ .text = state_text.items };
        const state_surf = try state_info.draw(ctx.withConstraints(
            .{},
            .{ .width = max_size.width, .height = 4 },
        ));

        // Create layout with all components
        const children = try ctx.arena.alloc(vxfw.SubSurface, 5);
        children[0] = .{ .surface = header_surf, .origin = .{ .row = 0, .col = 0 } };
        children[1] = .{ .surface = topics_surf, .origin = .{ .row = 2, .col = 0 } };
        children[2] = .{ .surface = separator_surf, .origin = .{ .row = 2, .col = topic_list_width } };
        children[3] = .{ .surface = messages_surf, .origin = .{ .row = 2, .col = topic_list_width + 1 } };
        children[4] = .{ .surface = state_surf, .origin = .{ .row = max_size.height - 4, .col = 0 } };

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

fn fetchMessages(consumer: *kafka.KafkaClient, model: *Model) !void {
    std.debug.print("Starting message fetch loop\n", .{});
    while (!model.should_exit.load(.seq_cst)) {
        if (try consumer.consumeMessage(model.allocator, 100)) |msg| {
            std.debug.print("Received message for topic: {s}\n", .{msg.topic});
            for (model.topics) |*topic| {
                if (std.mem.eql(u8, topic.name, msg.topic)) {
                    try topic.messages.append(msg);
                    std.debug.print("Added message to topic {s}, total messages: {d}\n", .{
                        topic.name,
                        topic.messages.items.len,
                    });
                    break;
                }
            }
        }
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var consumer = try kafka.KafkaClient.init(allocator, .Consumer, "my-group-id");
    defer consumer.deinit();

    std.debug.print("Getting topics\n", .{});
    const topics = try consumer.getTopics(allocator, 5000);
    defer {
        for (topics) |*topic| {
            topic.deinit();
        }
        allocator.free(topics);
    }

    std.debug.print("Available topics:\n", .{});
    for (topics) |topic| {
        std.debug.print("Topic: {s}, Partitions: {d}\n", .{ topic.name, topic.partition_count });
    }

    std.debug.print("subscribing to topics\n", .{});
    try consumer.subscribe(topics);
    std.debug.print("subscribed to topics\n", .{});

    // Get metadata
    // try consumer.getMetadata(5000);
    const info = try kafka.getConsumerGroupInfo(&consumer, allocator, 5000);
    defer {
        for (info.groups) |*group| {
            group.deinit();
        }
        allocator.free(info.groups);
    }

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    const model = try Model.init(allocator, topics, info.state_info);
    defer model.deinit();

    std.debug.print("fetching messages\n", .{});

    var thread = try std.Thread.spawn(.{}, fetchMessages, .{ &consumer, model });
    defer thread.join();

    std.debug.print("got messages!\n", .{});

    try app.run(model.widget(), .{});
}
