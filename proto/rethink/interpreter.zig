const std = @import("std");
const types = @import("types.zig");

const Token = types.Token;
const Arg = types.Arg;
const Variable = types.Variable;
const Param = types.Param;
const List = types.List;
const Builtins = @import("builtins.zig").Builtins;

const to_string = @import("builtins.zig").to_string;

pub const InterpreterError = error {
    EndOfFile,
    IndexOutOfBounds,
    InvalidAssignment,
    NullValue,
    // TODO: move these to finalizer
    UnknownIdentifier,
    NotFunction, 
    UnexpectedToken,
    NotChangeable,
    TypeMissmatch,
    MissplacedSymbol,
    UnknownVariable,
    WrongArgCount,
    ArgTypeMissmatch,
} || std.mem.Allocator.Error
  || std.process.RunError
;

pub const Interpreter = struct {
    alloc:std.mem.Allocator,
    io:std.Io,

    pub fn init(io:std.Io, alloc:std.mem.Allocator) !Interpreter {
        return .{
            .io = io,
            .alloc = alloc,
        };
    }

    pub fn do(self:*Interpreter, base:std.process.Init.Minimal, block:Block) !?Token {
        const alloc = block.alloc;
        if (block.namespace.get("main")) |*entry| {
            if (entry.tok.type == .block) {
                errdefer std.debug.print("root\n", .{});
                var main = entry.tok.type.block;
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
                            try args.append(alloc, .no_line_num(.{ .list = list }));
                        },
                        else => @panic("invalid main arg"),
                    };
                }
                var itr = block.namespace.iterator();
                while (itr.next()) |name_entry| {
                    const value = name_entry.value_ptr.*;
                    try main.to_namespace(
                        @constCast(name_entry.key_ptr.*),
                        value.changeable,
                        value.tok,
                    );
                }
                _ = try main.run(self.io, args.items);
            } else
                @panic("main not a label");
        } else
            @panic("no main");
        return null;
    }
};

pub const Block = struct {
    io:std.Io, //ugh
    params:[]Param,
    args:?[]Token = null,
    name:?[]u8, //null for root
    code:std.ArrayList(Token), //so I can iterate backwords, popping off of it as I go
    namespace:std.StringHashMap(NamespaceEntry),
    alloc:std.mem.Allocator,
    arena:std.heap.ArenaAllocator,
    is_label:bool = true,

    pub const NamespaceEntry = struct {
        tok:Token,
        changeable:bool
    };

    pub fn init(
        alloc:std.mem.Allocator,
        name:?[]u8,
        params:?[]Param,
        is_fn:bool
    ) Block {
        return .{
            .io = undefined,
            .namespace = .init(alloc),
            .alloc = alloc,
            .arena = .init(alloc),
            .name = name,
            .code = .empty,
            .params = params orelse @constCast(&[_]Param{}),
            .is_label = !is_fn,
        };
    }
    pub fn to_namespace(self:*Block, name:[]u8, changeable:bool, thing:Token) !void {
        try self.namespace.put(
            try self.alloc.dupe(u8, name),
            .{ .tok = thing, .changeable = changeable }
        );
    }
    pub fn deinit(self:*Block, alloc:std.mem.Allocator) void {
        self.code.deinit(alloc);
        self.namespace.deinit();
        _ = self.arena.deinit();
    }

    pub const CallOpts = struct {
        from_declaration:bool = false,
    };

    pub fn call(
        self:*Block,
        func:types.Func,
        i:*usize,
        comptime opts:CallOpts,
        tok:if (opts.from_declaration) Variable.Value.Declaration else Token,
    ) InterpreterError!?Token {
        const passed_args =
            if (!opts.from_declaration)
                try self.collect_args(i, tok)
            else blk: {
                var res:std.ArrayList(Token) = .empty;
                defer res.deinit(self.alloc);
                // FIXME: figure out the strange memory behavior
                //  (probably use-after free) for a less hacky "solution"
                for (tok.value[2..tok.value.len-1]) |ident|
                    try res.append(self.alloc, .no_line_num(ident.*));
                break :blk try res.toOwnedSlice(self.alloc);
            };
        defer self.alloc.free(passed_args);
        switch (func) {
            .builtin => |builtin| return try Builtins.run(self.alloc, builtin, passed_args),
            .local => |local| {
                if (self.namespace.get(local)) |*f| {
                    if (f.tok.type != .block)
                        return error.NotFunction
                    else if (f.tok.type.block.name) |_|
                        return try @constCast(f).tok.type.block.run(self.io, passed_args)
                    else
                        return error.NotFunction;
                } else {
                    std.debug.print("\n{s}(...) <- ", .{local});
                    return error.UnknownIdentifier;
                }
            },
            .shell => |cmd| return try self.exec(cmd, passed_args),
            .external => unreachable, // TODO: module system
        }
        unreachable; //uncaught; 'func' couldn't return value
    }

    pub fn resolve_declaration(
        self:*Block,
        declaration:Variable.Value.Declaration,
        i:*usize
    ) !Token.TokenType {
        for (0..declaration.value.len) |j| {
            const tok = declaration.value[j].*;
            switch (tok) {
                .ident => |ident| switch (ident) {
                    .func => |func| {
                        const res = (try self.call(
                            func, i, .{ .from_declaration = true },
                            declaration,
                        )).?.type;
                        return res;
                    },
                    else => {},
                },
                else => {},
            }
        } else
            return declaration.value[0].*;
    }

    pub fn do_var(self:*Block, variable:Variable, i:*usize) !?Token {
        switch (variable.value) {
            .declaration => |declaration| {
                const value = try self.resolve_declaration(declaration, i);
                // TODO: refactor namespace to track var type (set vs let)
                try self.to_namespace(
                    declaration.name,
                    variable.type orelse .set != .set,
                    .no_line_num(value)
                );
            },
            .name => |name| {
                if (self.code.items.len <= i.*+2)
                    return error.EndOfFile;
                i.* += 1;
                var tok = self.code.items[i.*];
                i.* += 1;
                for ([_]bool{
                    tok.type == .symbol,
                    tok.type.symbol == .@"=",
                }) |check| {
                    if (!check) {
                        std.debug.print("|{s}| (line {d} of {s})\n", .{
                            @tagName(tok.type),
                            tok.line_number,
                            self.name orelse "[unlabled block]"
                        });
                        return error.UnexpectedToken;
                    }
                }
                tok = self.code.items[i.*];
                const assignee = (try self.resolve_var(variable))[0];
                const assigner = if (tok.is_variable()) blk: {
                    const resolved = try self.resolve_var(tok.type.ident.variable);
                    // TODO: splat into set of vars
                    if (resolved.len > 1) return error.InvalidAssignment;
                    break :blk resolved[0];
                } else
                    tok;
                const have = @intFromEnum(assigner.type);
                const want = @intFromEnum(assignee.type);
                if (have != want) return error.TypeMissmatch;
                const original = self.namespace.getPtr(name.name) orelse unreachable; //uncaught
                if (original.*.changeable)
                    original.*.tok = assigner
                else
                    return error.NotChangeable;
            },
            else => return error.UnexpectedToken,
        }
        return null;
    }

    pub fn exec(self:*Block, name:[]u8, args:[]Token) InterpreterError!?Token {
        _ = .{ self, name, args };
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer _ = arena.deinit();
        const tmp_alloc = arena.allocator();
        const argv = blk: {
            var res:std.ArrayList([]const u8) = .empty;
            defer res.clearAndFree(tmp_alloc);
            try res.append(tmp_alloc, try tmp_alloc.dupe(u8, name));
            for (args) |a| {
                const strung = try to_string(tmp_alloc, @constCast(&[_]Token{a}));
                try res.append(tmp_alloc, @constCast(strung.type.string));
            }
            break :blk try res.toOwnedSlice(tmp_alloc);
        };
        const res = try std.process.run(tmp_alloc, self.io, .{ .argv = argv });
        const output =
            if (res.stdout.len < 1)
                res.stderr
            else
                res.stdout;
        return .no_line_num(.{ .string = try self.alloc.dupe(u8, output) });
    }

    pub fn run(self:*Block, io:std.Io, args:[]Token) InterpreterError!?Token {
        errdefer std.debug.print("|{s}| <- ", .{self.name orelse "[unnamed]"});
        self.io = io;

        try self.load_args(args);
        var i:usize = 0;
        while (i < self.code.items.len) : (i += 1) {
            var tok = self.code.items[i];
            switch (tok.type) {

                .ident => |ident| {
                    switch (ident) {
                        .func => |func| _ = try self.call(func, &i, .{}, tok),
                        .variable => |variable| {
                            _ = self.do_var(variable, &i) catch |e| {
                                std.debug.print("({any})", .{variable.value});
                                return e;
                            };
                        },
                        .unknown => |thing|
                            std.debug.panic("uncaught unknown ident: |{s}|\n", .{thing}),
                    }
                },

                .block => |*block| {
                    var blk = block.*;
                    var itr = self.namespace.iterator();
                    while (itr.next()) |entry| {
                        const v = entry.value_ptr.*;
                        try blk.to_namespace(@constCast(entry.key_ptr.*), v.changeable, v.tok);
                    }
                    _ = try blk.run(self.io, @constCast(&[_]Token{}));
                },

                .symbol => |symbol| if (symbol != .@";") {
                    std.debug.print("{any}\n", .{symbol});
                    return error.MissplacedSymbol;
                },

                else => std.debug.panic("{any}", .{tok.type}), //Block.run()
            }
        }
        return null;
    }

    pub fn resolve_var(self:*Block, origin:Variable) ![]Token {
        var token:Token = .no_line_num(.{ .ident = .{ .variable = origin } });
        while (token.is_variable()) {
            const variable = token.type.ident.variable;
            token = switch (variable.value) {
                .arg => |a| switch (a) {
                    .plain => |n| self.args.?[n],
                    .keyword => |key| switch (key) {
                        .@"count" => Token.mk_num(null, usize, self.args.?.len),
                        .@",,", .splat => @panic("TODO: splat args"),
                    },
                    else => unreachable,
                },
                .name => |name| blk: {
                    var match = (self.namespace.get(name.name) orelse {
                        return error.UnknownVariable;
                    }).tok;
                    if (name.flag) |flag| {
                        // TODO: stuff otherthan list indexing
                        if (match.type == .list) switch (flag.list) {
                            .idx => |idx| {
                                break :blk try match.type.list.get_token(idx);
                            },
                            .keyword => |keyword| switch (keyword) {
                                .count => return @constCast(&[_]Token{Token.mk_num(
                                    null, usize, match.type.list.count()
                                )}),
                                .splat, .@",," => {
                                    var m = (self.namespace.get(name.name) orelse {
                                        return error.UnknownVariable;
                                    }).tok;
                                    return try m.type.list.splat(self.alloc);
                                },
                            }
                        };
                    }
                    if (!match.is_variable()) return @constCast(&[_]Token{ match });
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
                .ident => |ident| switch (ident) {
                    .variable => |variable| {
                        const resolved = try self.resolve_var(variable);
                        for (resolved) |v|
                            try mem.append(self.alloc, v);
                        continue;
                    },
                    .func => |func| {
                        if (try self.call(func, &i, .{}, tok)) |return_value|
                            try mem.append(self.alloc, return_value)
                        else
                            return error.NullValue;
                    },
                    else => unreachable, // TODO: values from function calls
                },
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
                    try self.to_namespace(param.name orelse unreachable, false, args[i])
                else
                    return error.ArgTypeMissmatch;
            },
            .int, .uint => {
                if (args[i].type != .number)
                    return error.ArgTypeMissmatch;
                const expect = @tagName(args[i].type.number);
                const have = @tagName(param.type);
                if (std.mem.eql(u8, expect, have))
                    try self.to_namespace(param.name orelse unreachable, false, args[i])
                else
                    return error.ArgTypeMissmatch;
            },
            .list => {
                if (args[i].type == param.type)
                    try self.to_namespace(param.name orelse unreachable, false, args[i])
                else
                    return error.ArgTypeMissmatch;
            },
            else => unreachable,
        };
    }
};
