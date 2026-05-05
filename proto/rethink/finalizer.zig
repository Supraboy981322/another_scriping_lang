const std = @import("std");
const types = @import("types.zig");

pub const Finalizer = struct {
    logger:@import("logger.zig").Logger = .init,
    alloc:std.mem.Allocator,

    pub fn init(alloc:std.mem.Allocator) !Finalizer {
        return .{ .alloc = alloc };
    }

    pub fn recurse_namespace(
        self:*Finalizer,
        block:*types.Block,
        parent:?*types.Block
    ) !void {
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
                .block => |*blk| try self.recurse_namespace(blk, block),
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
    }

    pub fn resolve_idents(self:*Finalizer, block:*types.Block) !void {
        if (block.code.items.len < 1) {
            var itr = block.namespace.iterator();
            while (itr.next()) |entry|
                if (entry.value_ptr.tok.type == .block)
                    try self.resolve_idents(&entry.value_ptr.tok.type.block);
            return;
        }

        var declarations:std.ArrayList(types.Token) = .empty;
        defer declarations.deinit(self.alloc);

        loop: for (block.code.items) |*tok| if (tok.is_unknown()) {
            const ident_raw = tok.type.ident.unknown;
            const name:[]u8 = 
                if (std.mem.cutScalar(u8, ident_raw, '[')) |split|
                    @constCast(split[0])
                else
                    ident_raw;
            for (block.params) |p| if (p.name) |param_name|
                if (std.mem.eql(u8, name, param_name)) {
                    tok.type.ident = .{ .variable = .{
                        .type = .set,
                        .value = .{ .name = .{ .name = name } }
                    } };
                    continue :loop;
                };

            const match =
                if (block.namespace.get(name)) |from_namespace|
                    from_namespace
                else for (declarations.items) |declared| {
                    const item_name = declared.type.ident.variable.value.declaration.name;
                    if (std.mem.eql(u8, item_name, name))
                        break types.Block.NamespaceEntry{
                            .changeable = undefined,
                            .tok = declared,
                        };
                } else {
                    std.debug.panic(
                        "unknown ident: |{s}| <- (line {d} in {s}) ",
                        .{name, tok.line_number, block.name orelse "[unlabled block]"}
                    );
                    return error.UnknownIdent;
                };

            tok.type.ident =
                if (match.tok.type != .block)
                    .{ .variable = try .make(ident_raw) }
                else
                    .{ .func = .{ .local = name } };
        } else switch (tok.type) {
            .block => try self.resolve_idents(&tok.type.block),
            .ident => |ident| if (tok.is_variable()) {
                if (ident.variable.value == .declaration)
                    try declarations.append(self.alloc, tok.*);
            },
            else => {},
        };
    }

    pub const FinalizeOpts = struct {
        verify_ident_resolving:bool = false,
        panic_on_uncaught:bool = false,
    };

    pub fn verify_resolved(
        self:*Finalizer,
        block:*types.Block,
        comptime opts:FinalizeOpts
    ) if (opts.panic_on_uncaught) void else error{UncaughtUnknownIdent}!void {
        for (block.code.items) |tok| switch (tok.type) {
            .ident => |ident| switch (ident) {
                .unknown => |unknown| {
                    if (opts.panic_on_uncaught)
                        std.debug.panic("uncaught unknown ident: |{s}|", .{unknown})
                    else
                        return error.UncaughtUnknownIdent;
                },
                .variable => |variable| switch (variable.value) {
                    .declaration => |declaration| for (declaration.value) |token| {
                        if (token.ident == .unknown)
                            if (opts.panic_on_uncaught)
                                std.debug.panic(
                                "uncaught unknown ident: |{any}|", .{token.ident.unknown}
                            )
                            else
                                return error.UncaughtUnknownIdent;
                    },
                    else => {},
                },
                else => {},
            },
            .block => {
                if (opts.panic_on_uncaught)
                    self.verify_resolved(block, opts)
                else
                    try self.verify_resolved(block, opts);
            },
            else => {},
        };
    }

    pub fn do(self:*Finalizer, block:*types.Block, comptime opts:FinalizeOpts) !void {
        try self.logger.stage(.start, "finalizer", .{});
        defer self.logger.stage(.done, "finalizer", .{}) catch {};
        try self.recurse_namespace(block, null);
        try self.resolve_idents(block);
        if (opts.verify_ident_resolving)
            if (opts.panic_on_uncaught)
                self.verify_resolved(block, opts)
            else
                try self.verify_resolved(block, opts);
        return ;
    }
};
