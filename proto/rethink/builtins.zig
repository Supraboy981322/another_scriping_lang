const std = @import("std");
const types = @import("types.zig");

const Token = types.Token;
const Block = types.Block;

pub const Builtins = enum {
    print,

    pub fn run(which:Builtins, args:[]Token) !?Token {
        return switch (which) {
            .print => try print(args),
        };
    }

    pub fn is_builtin(name:[]u8) bool {
        return std.meta.stringToEnum(Builtins, name) != null;
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
