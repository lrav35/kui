const std = @import("std");
const vaxis = @import("vaxis");
const kafka = @import("kafka/client.zig");
const vxfw = vaxis.vxfw;
const c = @cImport({
    @cInclude("librdkafka/rdkafka.h");
});

/// Our main application state
const Model = struct {
    /// State of the counter
    count: u32 = 0,
    /// The button. This widget is stateful and must live between frames
    button: vxfw.Button,
    text: ?[]u8 = null,
    allocator: std.mem.Allocator,

    /// Helper function to return a vxfw.Widget struct
    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    pub fn deinit(self: *Model) void {
        if (self.text) |text| {
            self.allocator.free(text);
        }
    }

    /// This function will be called from the vxfw runtime.
    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            // The root widget is always sent an init event as the first event. Users of the
            // library can also send this event to other widgets they create if they need to do
            // some initialization.
            .init => return ctx.requestFocus(self.button.widget()),
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
            },
            // We can request a specific widget gets focus. In this case, we always want to focus
            // our button. Having focus means that key events will be sent up the widget tree to
            // the focused widget, and then bubble back down the tree to the root. Users can tell
            // the runtime the event was handled and the capture or bubble phase will stop
            .focus_in => return ctx.requestFocus(self.button.widget()),
            else => {},
        }
    }

    /// This function is called from the vxfw runtime. It will be called on a regular interval, and
    /// only when any event handler has marked the redraw flag in EventContext as true. By
    /// explicitly requiring setting the redraw flag, vxfw can prevent excessive redraws for events
    /// which don't change state (ie mouse motion, unhandled key events, etc)
    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        // The DrawContext is inspired from Flutter. Each widget will receive a minimum and maximum
        // constraint. The minimum constraint will always be set, even if it is set to 0x0. The
        // maximum constraint can have null width and/or height - meaning there is no constraint in
        // that direction and the widget should take up as much space as it needs. By calling size()
        // on the max, we assert that it has some constrained size. This is *always* the case for
        // the root widget - the maximum size will always be the size of the terminal screen.
        const max_size = ctx.max.size();

        // The DrawContext also contains an arena allocator that can be used for each frame. The
        // lifetime of this allocation is until the next time we draw a frame. This is useful for
        // temporary allocations such as the one below: we have an integer we want to print as text.
        // We can safely allocate this with the ctx arena since we only need it for this frame.
        const count_text = try std.fmt.allocPrint(ctx.arena, "{d}", .{self.count});
        const text: vxfw.Text = .{ .text = count_text };

        const hello_text = try std.fmt.allocPrint(ctx.arena, "{?s}", .{self.text});
        const hello: vxfw.Text = .{ .text = hello_text };

        // Each widget returns a Surface from it's draw function. A Surface contains the rectangular
        // area of the widget, as well as some information about the surface or widget: can we focus
        // it? does it handle the mouse?
        //
        // It DOES NOT contain the location it should be within it's parent. Only the parent can set
        // this via a SubSurface. Here, we will return a Surface for the root widget (Model), which
        // has two SubSurfaces: one for the text and one for the button. A SubSurface is a Surface
        // with an offset and a z-index - the offset can be negative. This lets a parent draw a
        // child and place it within itself
        const text_child: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try text.draw(ctx),
        };

        const hello_child: vxfw.SubSurface = .{
            .origin = .{ .row = 6, .col = 0 },
            .surface = try hello.draw(ctx),
        };

        const button_child: vxfw.SubSurface = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try self.button.draw(ctx.withConstraints(
                ctx.min,
                // Here we explicitly set a new maximum size constraint for the Button. A Button will
                // expand to fill it's area and must have some hard limit in the maximum constraint
                .{ .width = 16, .height = 3 },
            )),
        };

        // We also can use our arena to allocate the slice for our SubSurfaces. This slice only
        // needs to live until the next frame, making this safe.
        const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
        children[0] = text_child;
        children[1] = button_child;
        children[2] = hello_child;

        return .{
            // A Surface must have a size. Our root widget is the size of the screen
            .size = max_size,
            .widget = self.widget(),
            .focusable = false,
            // We didn't actually need to draw anything for the root. In this case, we can set
            // buffer to a zero length slice. If this slice is *not zero length*, the runtime will
            // assert that it's length is equal to the size.width * size.height.
            .buffer = &.{},
            .children = children,
        };
    }

    /// The onClick callback for our button. This is also called if we press enter while the button
    /// has focus
    fn onClick(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));

        self.count +|= 1;
        return ctx.consumeAndRedraw();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var consumer = try kafka.KafkaClient.init(allocator, .Consumer, "my-group-id");
    defer consumer.deinit();

    std.debug.print("Kafka consumer initialized\n", .{});

    // Get metadata
    try consumer.getMetadata(5000);

    // Subscribe to topics
    const topics = [_][]const u8{"kui-test"};
    try consumer.subscribe(&topics);
    std.debug.print("Subscribed to topics\n", .{});

    // get consumer info
    const info = try kafka.getConsumerGroupInfo(&consumer, allocator, 5000);

    defer {
        for (info.groups) |*group| {
            group.deinit();
        }
        allocator.free(info.groups);
    }

    if (info.state_info) |state| {
        std.debug.print("Consumer Group State:\n", .{});
        std.debug.print("  Is Rebalancing: {}\n", .{state.is_rebalancing});
        std.debug.print("  Last Rebalance Time: {d}\n", .{state.last_rebalance_time});
        std.debug.print("  Current State: {s}\n", .{state.current_state});
    }

    // Consume messages in a loop
    while (true) {
        if (try consumer.consumeMessage(allocator, 1000)) |msg| {
            defer msg.deinit();
            std.debug.print(
                \\Message Details:
                \\  Topic: {s}
                \\  Partition: {d}
                \\  Offset: {d}
                \\  Timestamp: {s}
                \\  Key: {?s}
                \\  Payload: {?s}
                \\
            , .{
                msg.topic,
                msg.partition,
                msg.offset,
                msg.timestamp,
                msg.key,
                msg.payload,
            });
        }
    }

    // const allocator = gpa.allocator();
    //
    // var app = try vxfw.App.init(allocator);
    // defer app.deinit();
    //
    // const version = c.rd_kafka_version();
    // const major = (version >> 24) & 0xFF;
    // const minor = (version >> 16) & 0xFF;
    // const revision = version & 0xFFFF;
    //
    // // We heap allocate our model because we will require a stable pointer to it in our Button
    // // widget
    // const model = try allocator.create(Model);
    // defer allocator.destroy(model);
    // defer model.deinit();
    //
    // const initial_text = try std.fmt.allocPrint(allocator, "Using librdkafka version: {d}.{d}.{d}", .{ major, minor, revision });
    //
    // // Set the initial state of our button
    // model.* = .{
    //     .count = 0,
    //     .button = .{
    //         .label = "Click me!",
    //         .onClick = Model.onClick,
    //         .userdata = model,
    //     },
    //     .text = initial_text,
    //     .allocator = allocator,
    // };
    //
    // try app.run(model.widget(), .{});
}
