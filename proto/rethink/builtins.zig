const std = @import("std");
const types = @import("types.zig");

const Token = types.Token;
const Block = types.Block;

pub const Builtins = enum {
    print,
    to_string,
    args,

    pub fn run(alloc:std.mem.Allocator, which:Builtins, args:[]Token) !?Token {
        return switch (which) {
            .print => try print(args),
            .to_string => try to_string(alloc, args),
            else => unreachable, //not a function
        };
    }

    pub fn is_builtin(name:[]u8) bool {
        return std.meta.stringToEnum(Builtins, name) != null;
    }

    pub fn is_func(which:Builtins) bool {
        return switch (which) {
            .args => false,
            else => true,
        };
    }

    pub fn make_var(which:Builtins, raw:[]u8) !types.Variable {
        if (raw.len < 1) unreachable; //need usage string
        switch (which) {
            .args => {
                if (raw[raw.len-1] != ']') unreachable; //not a flag
                const flag = raw[@tagName(which).len..];
                return .{ .value = .{ .arg = (types.Arg.make(flag)).? } };
            },
            else => unreachable, //not a variable
        }
    }
};

pub fn print(args:[]Token) !?Token {
    defer std.debug.print("\n", .{});
    for (args) |a| {
        switch (a.type) {
            .string => |str| std.debug.print("{s} ", .{str}),
            .number => |num| switch (num) {
                inline .uint, .int => |n| std.debug.print("{d} ", .{n}),
            },
            .list => |list| {
                for (list.value.items) |entry| switch (entry) {
                    .string => |s| std.debug.print("{s} ", .{s}),
                    .number => |num| switch (num) {
                        inline .uint, .int => |n| std.debug.print("{d} ", .{n}),
                    },
                    .bool => |b| std.debug.print("{} ", .{b}),
                    else => unreachable,
                };
            },
            else => std.debug.panic("{any}\n", .{a.type}),
        }
    }
    return null;
}

pub fn to_string(alloc:std.mem.Allocator, args:[]Token) !Token {
    var res:std.ArrayList(u8) = .empty;
    defer res.deinit(alloc);
    defer _ = res.pop();
    for (args, 0..) |arg, i| {
        switch (arg.type) {
            .string => |str| try res.appendSlice(alloc, str),
            .bool => |b| try res.appendSlice(alloc, if (b) "true" else "false"),
            .number => |num| switch (num) {
                inline .int, .uint => |n| try res.print(alloc, "{d}", .{n}),
            },
            .void => {},
            .byte => |b| try res.print(alloc, "{x}", .{b}),
            .list => |*list| {
                try res.appendSlice(alloc, ".[ ");
                const as_toks = try @constCast(list).splat(alloc);
                const as_string = try to_string(alloc, as_toks);
                try res.appendSlice(alloc, as_string.type.string);
                try res.appendSlice(alloc, " ]");
            },
            .block => |blk| try res.print(alloc,
                "<<block: {s}>>",
                .{blk.name orelse "[unlabeled]"}
            ),
            else => std.debug.panic("({d}) {any}\n", .{i, arg}),
        }
        try res.append(alloc, ' ');
    }
    return .no_line_num(.{ .string = try res.toOwnedSlice(alloc) });
}
