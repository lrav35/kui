const std = @import("std");
const vaxis = @import("vaxis");
const kafka = @import("kafka/client.zig");
const Cell = vaxis.Cell;
const TextInput = vaxis.widgets.TextInput;
const border = vaxis.widgets.border;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    consumer_message: ConsumerMessage,
};

const ConsumerMessage = struct {
    allocator: std.mem.Allocator,
    topic: ?[]const u8,
    msg_id: ?[]const u8,
    data: ?[]const u8,
    partition: ?[]const u8,
    offset: ?[]const u8,
    timestamp: ?[]const u8,
    timestampType: ?[]const u8,

    pub fn deinit(self: *const ConsumerMessage) void {
        if (self.topic) |s| self.allocator.free(s);
        if (self.msg_id) |s| self.allocator.free(s);
        if (self.data) |s| self.allocator.free(s);
        if (self.partition) |s| self.allocator.free(s);
        if (self.offset) |s| self.allocator.free(s);
        if (self.timestamp) |s| self.allocator.free(s);
        if (self.timestampType) |s| self.allocator.free(s);
    }
};

const AppState = struct {
    messages: std.ArrayList(ConsumerMessage),
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) AppState {
        return AppState{
            .messages = std.ArrayList(ConsumerMessage).init(alloc),
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *AppState) void {
        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        //fail test; can't try in defer as defer is executed after we return
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    // Initialize a tty
    var tty = try vaxis.Tty.init();
    defer tty.deinit();

    // Initialize Vaxis
    var vx = try vaxis.init(alloc, .{});
    // deinit takes an optional allocator. If your program is exiting, you can
    // choose to pass a null allocator to save some exit time.
    defer vx.deinit(alloc, tty.anyWriter());

    // The event loop requires an intrusive init. We create an instance with
    // stable pointers to Vaxis and our TTY, then init the instance. Doing so
    // installs a signal handler for SIGWINCH on posix TTYs
    //
    // This event loop is thread safe. It reads the tty in a separate thread
    var loop: vaxis.Loop(Event) = .{
        .tty = &tty,
        .vaxis = &vx,
    };
    try loop.init();

    // Start the read loop. This puts the terminal in raw mode and begins
    // reading user input
    try loop.start();
    defer loop.stop();

    // Optionally enter the alternate screen
    try vx.enterAltScreen(tty.anyWriter());

    // We'll adjust the color index every keypress for the border
    var color_idx: u8 = 0;

    // init our text input widget. The text input widget needs an allocator to
    // store the contents of the input
    var text_input = TextInput.init(alloc, &vx.unicode);
    defer text_input.deinit();

    // Sends queries to terminal to detect certain features. This should always
    // be called after entering the alt screen, if you are using the alt screen
    try vx.queryTerminal(tty.anyWriter(), 1 * std.time.ns_per_s);

    var app_state = AppState.init(alloc);
    defer app_state.deinit();

    // Kafka stuff
    var kafka_ctx = try kafka.KafkaContext.init(alloc, loop);
    defer kafka_ctx.deinit();

    const kafka_thread = try std.Thread.spawn(.{}, kafka.kafkaThread, .{&kafka_ctx});
    defer {
        kafka_ctx.should_quit.store(true, .release);
        kafka_thread.join();
    }

    // var message_scroll_offset: usize = 0; // For scrolling the message list
    // const MAX_DISPLAY_MESSAGES = 10; // How many messages to show at once

    while (true) {
        // nextEvent blocks until an event is in the queue
        const event = loop.nextEvent();
        // exhaustive switching ftw. Vaxis will send events if your Event enum
        // has the fields for those events (ie "key_press", "winsize")
        switch (event) {
            .key_press => |key| {
                color_idx = switch (color_idx) {
                    255 => 0,
                    else => color_idx + 1,
                };
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                    //TODO: scrolling functionality?...
                    // } else if (key.matches('k', .{})) { // 'k' to scroll up messages
                    //     if (message_scroll_offset > 0) {
                    //         message_scroll_offset -= 1;
                    //     }
                    // } else if (key.matches('j', .{})) { // 'j' to scroll down messages
                    //     // Ensure we don't scroll past the available messages,
                    //     // considering how many are displayed at once.
                    //     if (app_state.messages.items.len > 0) {
                    //         const max_scroll = if (app_state.messages.items.len > MAX_DISPLAY_MESSAGES)
                    //             app_state.messages.items.len - MAX_DISPLAY_MESSAGES
                    //         else
                    //             0;
                    //         if (message_scroll_offset < max_scroll) {
                    //             message_scroll_offset += 1;
                    //         }
                    //     }
                } else {
                    try text_input.update(.{ .key_press = key });
                }
            },

            // winsize events are sent to the application to ensure that all
            // resizes occur in the main thread. This lets us avoid expensive
            // locks on the screen. All applications must handle this event
            // unless they aren't using a screen (IE only detecting features)
            //
            // The allocations are because we keep a copy of each cell to
            // optimize renders. When resize is called, we allocated two slices:
            // one for the screen, and one for our buffered screen. Each cell in
            // the buffered screen contains an ArrayList(u8) to be able to store
            // the grapheme for that cell. Each cell is initialized with a size
            // of 1, which is sufficient for all of ASCII. Anything requiring
            // more than one byte will incur an allocation on the first render
            // after it is drawn. Thereafter, it will not allocate unless the
            // screen is resized
            .winsize => |ws| try vx.resize(alloc, tty.anyWriter(), ws),
            .consumer_message => |kafka_msg| {
                try app_state.messages.append(kafka_msg);

                //TODO: could have some autoscroll here
                // // Auto-scroll to the newest message if not already scrolled by user
                // if (app_state.messages.items.len > MAX_DISPLAY_MESSAGES) {
                //     message_scroll_offset = app_state.messages.items.len - MAX_DISPLAY_MESSAGES;
                // } else {
                //     message_scroll_offset = 0;
                // }

                vx.queueRefresh(); // Trigger a redraw
            },
            .focus_in => {
                // Vaxis might send this, typically you'd queue a refresh
                vx.queueRefresh();
            },
        }

        // vx.window() returns the root window. This window is the size of the
        // terminal and can spawn child windows as logical areas. Child windows
        // cannot draw outside of their bounds
        const win = vx.window();

        // Clear the entire space because we are drawing in immediate mode.
        // vaxis double buffers the screen. This new frame will be compared to
        // the old and only updated cells will be drawn
        win.clear();

        // Create a style
        const style: vaxis.Style = .{
            .fg = .{ .index = color_idx },
        };

        // Create a bordered child window
        const child = win.child(.{
            .x_off = win.width / 2 - 20,
            .y_off = win.height / 2 - 3,
            .width = 40,
            .height = 3,
            .border = .{
                .where = .all,
                .style = style,
            },
        });

        // Draw the text_input in the child window
        text_input.draw(child);

        // Render the screen. Using a buffered writer will offer much better
        // performance, but is not required
        try vx.render(tty.anyWriter());
    }
}
