const std = @import("std");
const types = @import("types.zig");

pub const Finalizer = struct {
    logger:@import("logger.zig").Logger = .init,

    pub fn init(_:std.mem.Allocator) !Finalizer {
        return .{};
    }

    pub fn recurse(
        self:*Finalizer,
        block:*types.Block,
        parent:?*types.Block
    ) !*types.Block {
        try self.logger.task(.start, "finalizer.recurse(\"{s}\", \"{s}\")", .{
            block.name orelse "[unlabeled block]",
            if (parent) |p| p.name orelse "[unlabeled block]" else "[root]"
        });
        defer self.logger.task(.done, "finalizer.recurse(\"{s}\", \"{s}\")", .{
            block.name orelse "[unlabeled block]",
            if (parent) |p| p.name orelse "[unlabeled block]" else "[root]"
        }) catch {};

        var block_itr = block.namespace.iterator();
        while (block_itr.next()) |entry| {
            _ = switch (entry.value_ptr.tok.type) {
                .block => |*blk| try self.recurse(blk, block),
                else => {},
            };
        }
        if (parent) |p| {
            var parent_itr = p.namespace.iterator();
            while (parent_itr.next()) |entry| {
                const name = @constCast(entry.key_ptr.*);
                const value = entry.value_ptr.*;
                try self.logger.task(.operation, "from parent:|{s}|", .{name});
                defer self.logger.task(.done, "from parent:|{s}|", .{name}) catch {};
                try block.to_namespace(name, value.changeable, value.tok);
            }
        }
        return block;
    }

    pub fn do(self:*Finalizer, block:*types.Block) !types.Block {
        try self.logger.stage(.start, "finalizer", .{});
        defer self.logger.stage(.done, "finalizer", .{}) catch {};
        return (try self.recurse(block, null)).*;
    }
};
