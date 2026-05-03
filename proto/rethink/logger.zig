const std = @import("std");

pub const Logger = struct {
    height:usize = 0,

    pub const init:@This() = .{};

    pub const ActionType = enum {
        start,
        done,
        operation,
    };

    pub fn task(
        self:*Logger,
        comptime action_type:ActionType,
        comptime msg:[]const u8,
        args:anytype
    ) !void {
        if (action_type != .done) {
            self.height += 1;
            std.debug.print("\t" ++ msg ++ "\n", args);
        } else {
            self.height -= 1;
            std.debug.print("\x1b[A\r\x1b[2K", .{});
        }
    }

    pub fn stage(
        self:*Logger,
        comptime action_type:ActionType,
        comptime msg:[]const u8,
        args:anytype,
    ) !void {
        switch (action_type) {
            .done => while (self.height > 0) : (self.height -= 1)
                std.debug.print("\x1b[A\r\x1b[2K", .{}),
            .start => {
                std.debug.assert(self.height == 0);
                self.height += 1;
                std.debug.print(msg ++ "\n", args);
            },
            .operation => unreachable,
        }
    }
};
