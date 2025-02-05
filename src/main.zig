const std = @import("std");
const vaxis = @import("vaxis");
const kafka = @import("kafka/client.zig");
const vxfw = vaxis.vxfw;
const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
});

/// Our main application state
const Model = struct {
    allocator: std.mem.Allocator,
    topics: [][]const u8,
    consumer_state: ?kafka.GroupStateInfo,
    selected_topic: usize = 0,

    pub fn init(allocator: std.mem.Allocator, topics: []kafka.TopicInfo, state: ?kafka.GroupStateInfo) !*Model {
        const model = try allocator.create(Model);
        errdefer allocator.destroy(model);
        const topic_names = try allocator.alloc([]const u8, topics.len);
        errdefer allocator.free(topic_names);
        for (topics, 0..) |topic, i| {
            topic_names[i] = try allocator.dupe(u8, topic.name);
        }

        model.* = .{
            .allocator = allocator,
            .topics = topic_names,
            .consumer_state = state,
        };
        return model;
    }

    pub fn deinit(self: *Model) void {
        if (self.topics.len > 0) {
            for (self.topics) |topic| {
                self.allocator.free(topic);
            }
            self.allocator.free(self.topics);
        }
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

        // Create topic list text
        var topic_text = std.ArrayList(u8).init(ctx.arena);
        for (self.topics, 0..) |topic, i| {
            const prefix = if (i == self.selected_topic) "> " else "  ";
            try topic_text.appendSlice(prefix);
            try topic_text.appendSlice(topic);
            try topic_text.append('\n');
        }

        const topics_list = vxfw.RichText{
            .text = &.{
                .{ .text = topic_text.items },
            },
        };

        const topics_surf = try topics_list.draw(ctx.withConstraints(
            .{},
            .{ .width = max_size.width, .height = max_size.height - 4 },
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

        // Create layout
        const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
        children[0] = .{ .surface = header_surf, .origin = .{ .row = 0, .col = 0 } };
        children[1] = .{ .surface = topics_surf, .origin = .{ .row = 2, .col = 0 } };
        children[2] = .{ .surface = state_surf, .origin = .{ .row = max_size.height - 4, .col = 0 } };

        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = children,
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var consumer = try kafka.KafkaClient.init(allocator, .Consumer, "my-group-id");
    defer consumer.deinit();

    const topics = try consumer.getTopics(allocator, 5000);
    defer {
        for (topics) |*topic| {
            topic.deinit();
        }
        allocator.free(topics);
    }

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

    try app.run(model.widget(), .{});

    // if (info.state_info) |state| {
    //     std.debug.print("Consumer Group State:\n", .{});
    //     std.debug.print("  Is Rebalancing: {}\n", .{state.is_rebalancing});
    //     std.debug.print("  Last Rebalance Time: {d}\n", .{state.last_rebalance_time});
    //     std.debug.print("  Current State: {s}\n", .{state.current_state});
    // }
    //
    // // Consume messages in a loop
    // while (true) {
    //     if (try consumer.consumeMessage(allocator, 1000)) |msg| {
    //         defer msg.deinit();
    //         std.debug.print(
    //             \\Message Details:
    //             \\  Topic: {s}
    //             \\  Partition: {d}
    //             \\  Offset: {d}
    //             \\  Timestamp: {s}
    //             \\  Key: {?s}
    //             \\  Payload: {?s}
    //             \\
    //         , .{
    //             msg.topic,
    //             msg.partition,
    //             msg.offset,
    //             msg.timestamp,
    //             msg.key,
    //             msg.payload,
    //         });
    //     }
    // }

}
