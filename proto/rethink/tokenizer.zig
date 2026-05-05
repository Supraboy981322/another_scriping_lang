const std = @import("std");
const types = @import("types.zig");
const hlp = @import("helpers.zig");

const Token = types.Token;
const Variable = types.Variable;
const Arg = types.Arg;
const Block = types.Block;

// TODO: move these to the helpers and just merge the types
pub const TokenizerError = error {
    BadTypeHint,
    MissplacedSymbol,
    InvalidParameterType,
    MissingParameterName,
    MissingParameterType,
    Overflow,
    InvalidCharacter,
    InvalidVariableName,
    InvalidListFlag,
    TypeMissmatch,
    IllegalType,
    UnexpectedByte,
    InvalidSymbol,
    NotInitialized,
    InvalidBuiltin,
    MissingFlag,
} || std.mem.Allocator.Error
  || hlp.DepthTrackerError
  || SeekError
;

pub const SeekError = error {
    EndOfFile,
    NotInitialized,
} || std.Io.Reader.DelimiterError;

pub const Tokenizer = struct {
    logger:@import("logger.zig").Logger = .init,
    alloc:std.mem.Allocator,
    reader:?*std.Io.Reader = null,
    arena:std.heap.ArenaAllocator,
    line_number:usize = 0,

    pub const CollectResult = struct {
        name:[]u8,
        token:Token,
    };

    pub fn init(alloc:std.mem.Allocator) !Tokenizer {
        const foo:Tokenizer = .{
            .alloc = alloc,
            .reader = null,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
        return foo;
    }

    pub fn deinit(self:*Tokenizer) void {
        self.mem.deinit(self.alloc);
        _ = self.arena.deinit();
    }


    pub const SeekOpts = struct {
        null_on_eof:bool = true,
        substitute_null:?u8 = null,
    };

    pub fn next(
        self:*Tokenizer,
        comptime opts:SeekOpts
    ) SeekError!if (opts.null_on_eof) ?u8 else u8 {
        if (self.reader == null) return error.NotInitialized;
        const b = self.reader.?.takeByte() catch |e| {
            if (e != error.EndOfStream) return e;
            if (!opts.null_on_eof) return error.EndOfFile;
            if (opts.substitute_null) |c| return c;
            return null;
        };
        return try self.seek_hook(opts, b);
    }

    pub fn nextEOF(self:*Tokenizer) SeekError!u8 {
        return try self.next(.{ .null_on_eof = false });
    }

    pub fn seek_hook(
        self:*Tokenizer,
        comptime opts:SeekOpts,
        byte:if (opts.null_on_eof) ?u8 else u8,
    ) SeekError!if (opts.null_on_eof) ?u8 else u8 {
        const b =
            if (opts.null_on_eof)
                if (byte) |b| b else return byte
            else
                byte;

        if (b == '\n') self.line_number += 1;

        switch (b) {
            '#' => if (try self.peekEOF() == '(') {
                var depth:usize = 1;
                _ = try self.next(.{});
                while (true) {
                    switch (try self.nextEOF()) {
                        '(' => depth += 1,
                        ')' => depth -= 1,
                        else => {},
                    }
                    if (depth == 0) return self.next(opts);
                } else
                    return error.EndOfFile;
            },
            else => {},
        }
        return byte;
    }

    pub fn peek(
        self:*Tokenizer,
        comptime opts:SeekOpts
    ) SeekError!if (opts.null_on_eof) ?u8 else u8 {
        if (self.reader == null) return error.NotInitialized;
        const b = self.reader.?.peekByte() catch |e| {
            if (e != error.EndOfStream) return e;
            if (!opts.null_on_eof) return error.EndOfFile;
            if (opts.substitute_null) |c| return c;
            return null;
        };
        return try self.seek_hook(opts, b);
    }

    pub fn peekEOF(self:*Tokenizer) SeekError!u8 {
        return self.peek(.{ .null_on_eof = false });
    }

    pub fn take_delim(
        self:*Tokenizer,
        comptime end:u8,
        comptime opts:SeekOpts,
    ) !if (opts.null_on_eof) ?[]u8 else []u8 {
        var buf:std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        var string:?u8 = null;
        while (try self.next(opts)) |b| {
            if (string) |s| {
                if (b == s) string = null;
                try buf.append(self.alloc, b);
                continue;
            } else
                if (b == '"') string = b;
            if (b == end) return try buf.toOwnedSlice(self.alloc);
            try buf.append(self.alloc, b);
        }
        return null;
    }

    pub fn recurse(self:*Tokenizer, name:?[]u8) !Block {
        try self.logger.task(.start,
            "tokenizer.recurse(\"{s}\")",
            .{name orelse "[unlabled block]"}
        );
        defer self.logger.task(.done,
            "tokenizer.recurse(\"{s}\")",
            .{name orelse "[unlabled block]"}
        ) catch {};
        var tokenizer:Tokenizer = try .init(self.alloc);
        return try tokenizer.do(self.reader.?, name);
    }

    pub fn do(
        self:*Tokenizer,
        reader:*std.Io.Reader,
        name:?[]u8
    ) TokenizerError!Block {
        try self.logger.stage(.start,
            "tokenizer.do(\"{s}\")",
            .{name orelse "[unlabled block]"}
        );
        defer self.logger.stage(.done,
            "tokenizer.do(\"{s}\")",
            .{name orelse "[unlabled block]"}
        ) catch {};

        // TODO:  helpers to dupe result so arena can be reset
        // defer self.arena.reset(.free_all);
        const alloc = self.arena.allocator();
        if (self.reader == null) self.reader = reader;

        var mem:std.ArrayList(u8) = .empty;
        defer mem.deinit(alloc);

        var res:Block = .init(self.alloc, name, null, true);

        var depth_tracker:hlp.DepthTracker(u8) = try .init();
        _ = &depth_tracker; // NOTE: may need this

        var esc:bool = false;
        var label_name:?[]u8 = null;
        var string:?u8 = null;

        loop: while (try self.next(.{})) |b| {
            if (esc) {
                esc = false;
                try mem.append(alloc, b);
                continue;
            }

            // TODO: refactor this for string interpolation
            if (string) |s| {
                if (b == s) {
                    string = null;
                    const str:Token = .{
                        .line_number = self.line_number,
                        .type = .{ .string = try mem.toOwnedSlice(self.alloc) }
                    };
                    try res.code.append(self.alloc, str);
                } else
                    try mem.append(alloc, b);
                continue;
            }

            blk: {
                for ([_]bool{
                    std.ascii.isWhitespace(b),
                    Token.byte_looks_like_symbol(b),
                }) |check| if (check) {
                    const info = try self.whitespace(alloc, &res, &mem, b);
                    if (info.skip) continue :loop;
                    break :blk;
                };
            }

            switch (b) {
                '"' => string = b,
                '\\' => esc = true,
                '{' => {
                    defer {
                        if (label_name) |_| label_name = null;
                    }
                    var block = try self.recurse(label_name);
                    block.is_label = label_name != null;
                    const as_token:Token = .{
                        .line_number = self.line_number,
                        .type = .{ .block = block }
                    };
                    if (label_name) |label|
                        try res.to_namespace(label, false, as_token)
                    else
                        try res.code.append(self.alloc, as_token);
                },
                '}' => return res,
                '.' => {
                    if (mem.items.len > 0)
                        @panic("TODO: dereference into structs");
                    const literal = try self.dot_literal(alloc, &mem);
                    try res.code.append(self.alloc, literal);
                },
                ':' => {
                    if (label_name) |_|
                        return error.MissplacedSymbol; //colon
                    label_name = try mem.toOwnedSlice(self.alloc);
                },
                else => try mem.append(alloc, b),
            }
        }
        return res;
    }

    pub fn collect_within(
        self:*Tokenizer,
        comptime start:u8,
        comptime end:u8,
        alloc:std.mem.Allocator,
        mem:*std.ArrayList(u8),
    ) ![]Token {
        var res:std.ArrayList(Token) = .empty;
        defer res.deinit(alloc);
        var depth:usize = 1;
        while (try self.next(.{})) |b| {
            switch (b) {
                start => depth += 1,
                end => depth -= 1,
                else => {
                    if (std.ascii.isWhitespace(b) or Token.byte_looks_like_symbol(b)) {
                        if (mem.items.len > 0) {
                            const raw = try mem.toOwnedSlice(self.alloc);
                            const new = (try Token.make(self.line_number, raw)).?;
                            try res.append(alloc, new);
                        } if (!std.ascii.isWhitespace(b)) {
                            const new = (try Token.make_from_byte(self.line_number, b)).?;
                            try res.append(alloc, new);
                        }
                    } else
                        try mem.append(alloc, b);
                },
            }
            if (depth == 0) break;
        }
        if (mem.items.len > 0) {
            const raw = try mem.toOwnedSlice(self.alloc);
            const new = (try Token.make(self.line_number, raw)).?;
            try res.append(self.alloc, new);
        }
        return try res.toOwnedSlice(self.alloc);
    }

    pub fn dot_literal(
        self:*Tokenizer,
        alloc:std.mem.Allocator,
        mem:*std.ArrayList(u8)
    ) !Token {
        std.debug.assert(mem.items.len == 0);
        const literal_type = try self.next(.{}) orelse return error.EndOfFile;
        switch (literal_type) {
            '{' => @panic("TODO: object literal"),
            '[' => {
                var list:types.List = .init(.DYNAMIC);
                const values = try self.collect_within(
                    '[', ']', alloc, mem
                );
                try list.append_many_fat(self.alloc, values);
                _ = try list.check_type(.{ .solidify = true });
                return .{
                    .line_number = self.line_number,
                    .type = .{ .list = list }
                };
            },
            else => return error.MissplacedSymbol,
        }
    }

    pub fn collect_fn(
        self:*Tokenizer,
        alloc:std.mem.Allocator,
        mem:*std.ArrayList(u8),
    ) !CollectResult {
        const fn_name = try self.take_delim('(', .{ .null_on_eof = true }) orelse {
            return error.EndOfFile;
        };

        var params:std.ArrayList(types.Param) = .empty;
        defer params.deinit(alloc);

        var c:u8 = try self.next(.{ .null_on_eof = false });
        c = while (true) : (c = try self.next(.{ .null_on_eof = false })) {
            if (std.ascii.isWhitespace(c) or c == ')') {
                if (mem.items.len == 0 and c == ')') break try self.peekEOF();
                var type_hint_string:?[]u8 = null;
                if (std.mem.count(u8, mem.items, "[") > 0) blk: {
                    _, const dumb_const_type_hint_string = std.mem.cut(
                        u8, mem.items, "["
                    ) orelse break :blk;
                    type_hint_string = @constCast(dumb_const_type_hint_string);
                    type_hint_string = type_hint_string.?[0..type_hint_string.?.len-1];
                }
                const param_type:Token.Types = Token.TokenType.make(
                    if (type_hint_string) |hint|
                        mem.items[0..mem.items.len-hint.len-2]
                    else
                        mem.items
                ) orelse
                    return error.InvalidParameterType;
                const type_hint:?Token.TypeHint = blk: {
                    if (type_hint_string) |hint_raw| {
                        switch (param_type) {
                            .list => break :blk .{
                                .list = std.meta.stringToEnum(
                                    Token.Types, hint_raw
                                ) orelse
                                    return error.BadTypeHint,
                            },
                            else => return error.BadTypeHint,
                        }
                    } else
                        break :blk null;
                };
                mem.clearAndFree(alloc);

                var skeleton = params.pop() orelse return error.MissingParameterName;
                if (skeleton.type != .void)
                    return error.MissingParameterName;

                skeleton.type_hint = type_hint;
                skeleton.type = param_type;

                try params.append(self.alloc, skeleton);
            }
            switch (c) {
                ')' => break try self.peekEOF(),
                '(' => return error.MissplacedSymbol,
                ':' => {
                    try params.append(self.alloc,
                        .skeleton(try mem.toOwnedSlice(self.alloc))
                    );
                },
                else => {
                    try mem.append(alloc, c);
                },
            }
        } else
            return error.EndOfFile;
        while (std.ascii.isWhitespace(c)) c = try self.next(.{ .null_on_eof = false });
        var block:Block = try self.recurse(fn_name);
        block.params = try params.toOwnedSlice(self.alloc);
        return .{
            .name = fn_name,
            .token = .{
                .line_number = self.line_number,
                .type = .{ .block = block }
            }
        };
    }

    pub fn collect_var(
        self:*Tokenizer,
        alloc:std.mem.Allocator,
        _:*Block,
        mem:*std.ArrayList(u8),
        var_type:Token.Keywords
    ) !CollectResult {
        const matched_type = std.meta.stringToEnum(
            Variable.Type, @tagName(var_type)
        ) orelse unreachable; //invalid variable declaration type passed
        var name:?[]u8 = null;
        var symbol:?Token.Symbols = null;

        var value_toks:std.ArrayList(*Token.TokenType) = .empty;
        defer value_toks.deinit(alloc);

        while (std.ascii.isWhitespace(try self.peekEOF())) self.reader.?.toss(1);
        while (try self.next(.{})) |b| {
            const is_symbol = Token.byte_looks_like_symbol(b);
            if (is_symbol) if (symbol == null) {
                symbol = std.meta.stringToEnum(
                    Token.Symbols, &[_]u8{b}
                ) orelse {
                    return error.InvalidSymbol;
                };
            } else if (b != ';')
                try value_toks.append(alloc,
                    @constCast(&Token.TokenType{
                        .symbol = Token.byte_to_symbol(b).?
                    })
                );

            const do_split = is_symbol or std.ascii.isWhitespace(b);
            if (do_split and mem.items.len > 0) {
                const raw = try mem.toOwnedSlice(self.alloc);
                if (name == null)
                    name = raw
                else if (symbol == null) {
                    symbol = std.meta.stringToEnum(
                        Token.Symbols, raw
                    ) orelse {
                        return error.InvalidSymbol;
                    };
                } else {
                    const value = try self.alloc.create(Token.TokenType);
                    value.* = try Token.TokenType.new(raw);
                    const collected:CollectResult = .{
                        .name = name.?,
                        .token = .{
                            .line_number = self.line_number,
                            .type = .{ .ident = .{ .variable = .{
                                .type = matched_type,
                                .value = .{ .declaration = .{
                                    .name = name.?, 
                                    .value = value,
                                }}
                            }}}, // TODO: maybe I should refactor this struct
                        }
                    };
                    return collected;
                }
            }

            if (!is_symbol and !std.ascii.isWhitespace(b)) try mem.append(alloc, b);
        }
        return error.EndOfFile;
    }

    pub fn whitespace(
        self:*Tokenizer,
        alloc:std.mem.Allocator,
        res:*Block,
        mem:*std.ArrayList(u8),
        b:u8
    ) !struct{ skip:bool = true } {
        if (mem.items.len > 0) {
            const raw = try mem.toOwnedSlice(self.alloc);
            const new_token = (try Token.make(self.line_number, raw)).?;
            if (new_token.type == .keyword) switch (new_token.type.keyword) {
                .@"fn" => {

                    if (Token.byte_to_symbol(b)) |_|
                        try res.code.append(
                            self.alloc, (try Token.make_from_byte(self.line_number, b)).?
                        );

                    const function = try self.collect_fn(alloc, mem);
                    try res.to_namespace(function.name, false, function.token);

                    return .{};
                },
                .set, .let => |var_type| {
                    if (!std.ascii.isWhitespace(b))
                        return error.UnexpectedByte;
                    const new_var = try self.collect_var(alloc, res, mem, var_type);
                    try res.code.append(self.alloc, new_var.token);
                    return .{};
                },
                else => {},
            };
            try res.code.append(self.alloc, new_token);
        }

        if (Token.byte_looks_like_symbol(b))
            try res.code.append(self.alloc,
                (try Token.make_from_byte(self.line_number, b)).?
            );

        return .{};
    }
};
