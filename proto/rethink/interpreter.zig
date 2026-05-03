const std = @import("std");
const types = @import("types.zig");

const Token = types.Token;
const Arg = types.Arg;
const Variable = types.Variable;
const Param = types.Param;
const List = types.List;
const Builtins = @import("builtins.zig").Builtins;

pub const Interpreter = struct {
    alloc:std.mem.Allocator,
    io:std.Io,

    pub fn init(io:std.Io, alloc:std.mem.Allocator) !Interpreter {
        return .{
            .io = io,
            .alloc = alloc,
        };
    }

    pub fn do(_:*Interpreter, base:std.process.Init.Minimal, block:Block) !?Token {
        const alloc = block.alloc;
        if (block.namespace.get("main")) |*entry| {
            if (entry.type == .block) {
                errdefer std.debug.print("root\n", .{});
                var main = entry.type.block;
                var args:std.ArrayList(Token) = .empty;
                defer args.deinit(alloc);
                if (main.params.len > 0) blk: {
                    if (main.params.len == 1 and main.params[0].type == .void) break :blk;
                    for (main.params) |param| switch (param.type) {
                        .list => {
                            _ = std.meta.stringToEnum(
                                enum{ argv, args, @"_" }, param.name.?
                            ) orelse
                                return error.UnsupportedMainArg;

                            if (param.type_hint == null)
                                return error.WrongMainArgType;
                            if (param.type_hint.?.list != .string)
                                return error.WrongMainArgType;

                            var list:types.List = .{ .type = .string };

                            var itr = base.args.iterate();
                            while (itr.next()) |arg|
                                try list.append(alloc, .{ .string  = try alloc.dupe(u8, arg) });
                            try args.append(alloc, .{ .type = .{ .list = list  } });
                        },
                        else => @panic("invalid main arg"),
                    };
                }
                var itr = block.namespace.iterator();
                while (itr.next()) |name_entry| {
                    try main.to_namespace(
                        @constCast(name_entry.key_ptr.*),
                        name_entry.value_ptr.*
                    );
                }
                _ = try main.run(args.items);
            } else
                @panic("main not a label");
        } else
            @panic("no main");
        return null;
    }
};

pub const Block = struct {
    params:[]Param,
    args:?[]Token = null,
    name:?[]u8, //null for root
    code:std.ArrayList(Token), //so I can iterate backwords, popping off of it as I go
    namespace:std.StringHashMap(Token),
    alloc:std.mem.Allocator,
    arena:std.heap.ArenaAllocator,
    is_label:bool = true,
    pub fn init(alloc:std.mem.Allocator, name:?[]u8, params:?[]Param, is_fn:bool) Block {
        return .{
            .namespace = .init(alloc),
            .alloc = alloc,
            .arena = .init(alloc),
            .name = name,
            .code = .empty,
            .params = params orelse @constCast(&[_]Param{}),
            .is_label = !is_fn,
        };
    }
    pub fn to_namespace(self:*Block, name:[]u8, thing:Token) !void {
        try self.namespace.put(try self.alloc.dupe(u8, name), thing);
    }
    pub fn deinit(self:*Block, alloc:std.mem.Allocator) void {
        self.code.deinit(alloc);
        self.namespace.deinit();
        _ = self.arena.deinit();
    }

    pub fn run(self:*Block, args:[]Token) !?Token {
        errdefer std.debug.print("|{s}| <- ", .{self.name orelse "[unnamed]"});

        try self.load_args(args);
        var i:usize = 0;
        while (i < self.code.items.len) : (i += 1) {
            var tok = self.code.items[i];
            switch (tok.type) {

                .ident => |ident| {
                    const passed_args = try self.collect_args(&i, tok);
                    defer self.alloc.free(passed_args);
                    _ = Builtins.run(ident, passed_args) catch |e| {
                        if (e == error.InvalidBuiltin) {
                            if (self.namespace.get(ident)) |*func| {
                                if (func.type != .block)
                                    return error.NotFunction
                                else if (func.type.block.name) |_|
                                    _ = try @constCast(func).type.block.run(passed_args)
                                else
                                    return error.NotFunction;
                            } else {
                                std.debug.print("\n|{s}|\n", .{ident});
                                return error.UnknownIdentifier;
                            }
                        } else
                            return e;
                    };
                },

                .block => |*block| {
                    var blk = block.*;
                    var itr = self.namespace.iterator();
                    while (itr.next()) |entry|
                        try blk.to_namespace(@constCast(entry.key_ptr.*), entry.value_ptr.*);
                    _ = try blk.run(@constCast(&[_]Token{}));
                },

                .symbol => |symbol| if (symbol != .@";") {
                    std.debug.print("{any}\n", .{symbol});
                    return error.MissplacedSymbol;
                },
                .variable => |variable| switch (variable.value) {
                    .declaration => |declaration| {
                        // TODO: refactor namespace to track var type (set vs let)
                        try self.to_namespace(declaration.name, .{ .type = declaration.value.* });
                    },
                    .name => |name| {
                        if (self.code.items.len <= i+2)
                            return error.EndOfFile;
                        i += 1;
                        tok = self.code.items[i];
                        i += 1;
                        for ([_]bool{
                            tok.type == .symbol,
                            tok.type.symbol == .@"=",
                        }) |check|
                            if (!check) return error.UnexpectedToken;
                        tok = self.code.items[i];
                        const assignee = (try self.resolve_var(variable))[0];
                        const assigner = if (tok.type == .variable) blk: {
                            const resolved = try self.resolve_var(tok.type.variable);
                            if (resolved.len > 1) return error.InvalidAssignment; // TODO: splat into set of vars
                            break :blk resolved[0];
                        } else
                            tok;
                        const have = @intFromEnum(assigner.type);
                        const want = @intFromEnum(assignee.type);
                        if (have != want) return error.TypeMissmatch;
                        const original = self.namespace.getPtr(name.name) orelse unreachable; //uncaught
                        original.* = assigner;
                    },
                    else => return error.UnexpectedToken,
                },

                else => std.debug.panic("{any}", .{tok.type}), //Block.run()
            }
        }
        return null;
    }

    pub fn resolve_var(self:*Block, origin:Variable) ![]Token {
        var token:Token = .{ .type = .{ .variable = origin } };
        while (token.type == .variable) {
            const variable = token.type.variable;
            token = switch (variable.value) {
                .arg => |a| switch (a) {
                    .plain => |n| self.args.?[n],
                    .keyword => |key| switch (key) {
                        .@"count" => Token.mk_num(usize, self.args.?.len),
                        .@",,", .splat => @panic("TODO: splat args"),
                    },
                    else => unreachable,
                },
                .name => |name| blk: {
                    var match = self.namespace.get(name.name) orelse {
                        std.debug.print("\n|{any}|\n", .{name});
                        return error.UnknownVariable;
                    };
                    if (name.flag) |flag| {
                        // TODO: stuff otherthan list indexing
                        if (match.type == .list) switch (flag.list) {
                            .idx => |idx| {
                                break :blk try match.type.list.get_token(idx);
                            },
                            .keyword => |keyword| switch (keyword) {
                                .count => return @constCast(&[_]Token{Token.mk_num(
                                    usize, match.type.list.count()
                                )}),
                                .splat, .@",," => {
                                    var m = self.namespace.get(name.name) orelse {
                                        return error.UnknownVariable;
                                    };
                                    return try m.type.list.splat(self.alloc);
                                },
                            }
                        };
                    }
                    if (match.type != .variable) return @constCast(&[_]Token{ match });
                    break :blk match;
                },
                else => unreachable,
            };
        }
        return @constCast(&[_]Token{ token });
    }

    pub fn collect_args(self:*Block, start_pos:*usize, start_tok:Token) ![]Token {
        var mem:std.ArrayList(Token) = .empty;
        defer mem.deinit(self.alloc);
        var i = start_pos.*+1;
        defer {
            const start = start_pos.*;
            start_pos.* += i - start;
        }
        var tok = start_tok;
        var depth:u8 = 0;
        while (i < self.code.items.len) : (i += 1) {
            tok = self.code.items[i];
            if (tok.type == .symbol) {
                switch (tok.type.symbol) {
                    .@"(" => depth += 1,
                    .@")" => depth -= 1,
                    else => return error.MissplacedSymbol,
                }
                if (depth == 0) {
                    return try mem.toOwnedSlice(self.alloc);
                }
                continue;
            }
            switch (tok.type) {
                .variable => |variable| {
                    const resolved = try self.resolve_var(variable);
                    for (resolved) |v|
                        try mem.append(self.alloc, v);
                    continue;
                },
                .ident => unreachable,
                .block => @panic("TODO: nested function calls"),
                else => {},
            }
            try mem.append(self.alloc, tok);
        }
        return mem.toOwnedSlice(self.alloc);
    }

    pub fn load_args(self:*Block, args_raw:?[]Token) !void {
        if (self.name == null or self.is_label) {
            self.args = args_raw;
            return;
        }

        if (args_raw == null) {
            if (self.params.len > 0)
                return error.WrongArgCount;
            return;
        }

        const args = args_raw.?;
        if (args.len < 1) return;

        if (std.mem.eql(u8, "main", self.name.?)) {
            if (args.len == 1) if (args[0].type == .void) return;
            if (args.len > 0) if (args[0].type != .list)
                @panic("TODO: \"juicy main\" as the rest of the Zig community calls it");
        }

        if (self.params.len != args.len) return error.WrongArgCount;

        self.args = try self.arena.allocator().alloc(Token, args.len);

        for (self.params, 0..) |param, i| switch (param.type) {
            .string, .bool, .void => {
                if (args[i].type == param.type)
                    try self.to_namespace(param.name orelse unreachable, args[i])
                else
                    return error.ArgTypeMissmatch;
            },
            .int, .uint => {
                if (args[i].type != .number)
                    return error.ArgTypeMissmatch;
                const expect = @tagName(args[i].type.number);
                const have = @tagName(param.type);
                if (std.mem.eql(u8, expect, have))
                    try self.to_namespace(param.name orelse unreachable, args[i])
                else
                    return error.ArgTypeMissmatch;
            },
            .list => {
                if (args[i].type == param.type)
                    try self.to_namespace(param.name orelse unreachable, args[i])
                else
                    return error.ArgTypeMissmatch;
            },
            else => unreachable,
        };
    }
};
