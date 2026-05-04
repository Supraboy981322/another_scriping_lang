const std = @import("std");
const interpreter = @import("interpreter.zig");

pub const Builtins = @import("builtins.zig").Builtins;

pub const Param = struct {
    name:?[]u8,
    type:Token.Types = .void,
    type_hint:?Token.TypeHint = null,

    pub fn skeleton(name:[]u8) Param {
        return .{ .name = name };
    }
};

pub const Block = interpreter.Block;

pub const Arg = union(enum) {
    plain:usize,
    keyword:ArgKeyword,
    complex:[]u8, //parsed when used  TODO: advanced arg stuff
    token:*Token,
    pub const ArgKeyword = enum {
        @",,", splat, //splat
        count,
    };

    pub fn is_splat(self:Arg) !bool {
        if (self != .keyword)
            return error.ArgNotKeyword;
        return self.keyword == .@",," or self.keyword == .@"splat";
    }

    pub fn byte_to_keyword(b:u8) ?Arg {
        return Arg.to_keyword(@constCast(&[_]u8{b}));
    }
    pub fn to_keyword(str:[]u8) ?Arg {
        return .{ .keyword = std.meta.stringToEnum(ArgKeyword, str) orelse return null };
    }

    pub fn make(raw:[]u8) ?Arg {
        if (std.fmt.parseInt(usize, raw, 10)) |int| 
            return .{ .plain = int }
        else |_| {}

        if (raw[0] == '[' and raw[raw.len-1] == ']') {
            return
                if (Arg.to_keyword(raw[1..raw.len-1])) |match|
                    match
                else 
                    .{ .complex = raw, };
        }
        return null;
    }
};

pub const Variable = struct {
    type:?Type = null,
    value:Value,

    pub const Value = union(enum) {
        arg:Arg,
        name:NamedVariable,
        declaration:struct {
            name:[]u8,
            value:*Token.TokenType,
        },
    };

    pub const Type = enum { set, let };

    pub const NamedVariable = struct {
        name:[]u8,
        flag:?Flag = null,

        pub const Flag = union(enum) {
            list:Flag.List,

            pub const List = union(enum) {
                idx:usize, //index into list
                keyword:Arg.ArgKeyword, //stuff like 'count' and 'splat'
            };
        };
    };

    pub fn make(raw:[]u8) !Variable {
        if (Arg.make(raw)) |match| 
            return .{ .value = .{ .arg = match } };

        var named:Variable = .{
            .value = .{ .name = .{ .name = raw[if (raw[0] == '$') 1 else 0..] } },
        };

        const first_half, var second_half = std.mem.cut(
            u8, named.value.name.name, "["
        ) orelse
            return named;

        if (second_half[second_half.len-1] == ']') {
            named.value.name.name = @constCast(first_half);
            second_half = second_half[0..second_half.len-1];
            named.value.name.flag = .{
                // TODO: stuff otherthan lists
                .list =
                    if (std.fmt.parseInt(usize, second_half, 10)) |idx| .{
                        .idx = idx
                    } else |e| if (e == error.InvalidCharacter) .{
                        .keyword = std.meta.stringToEnum(
                            Arg.ArgKeyword, second_half
                        ) orelse
                            return error.InvalidListFlag,
                    } else
                        return e,
            };
        } else
            return error.InvalidVariableName;

        return named;
    }
};

pub const Func = union(enum) {
    builtin:Builtins,  //starts with '#'
    local:[]u8,
    external:[]u8, //starts with '@'
    shell:[]u8,
};

pub const Ident = union(enum) {
    variable:Variable,
    func:Func,
    unknown:[]u8,
};

pub const Token = union(enum) {
    type:TokenType,

    pub const Types = std.meta.Tag(TokenType);
    pub const TokenType = union(enum) {
        string:[]u8,
        block:Block,
        ident:Ident,
        symbol:Symbols,
        keyword:Keywords,
        list:List,
        bool:bool,
        byte:u8, // TODO: arbitrary bit width (probably can use some Zig stuff for that)
        number:union(enum) {
            int:i256,
            uint:u256,
        },

        //these exist to match a literal 'int' (for example) to a type
        int:void,
        uint:void,
        void:void,

        pub fn make(raw:[]u8) ?Types {
            const lazy_match = std.meta.stringToEnum(
                Types, raw
            ) orelse return null;
            switch (lazy_match) {
                .string, .bool, .int, .uint, .void, .list => return lazy_match,
                else => return null,
            }
        }
        // TODO: rename this
        pub fn new(raw:[]u8) !TokenType {
            return (try Token.make(raw) orelse unreachable).type;
        }
    };

    pub const @"void":Token = .{ .type = .{ .void = {} } };

    pub const TypeHint = union(enum) {
        list:Types,
    };

    pub const Keywords = enum {
        @"fn",
        
        set, let,

        // TODO: everything after this line
        @"if", @"?",
        @"for",
        @"while",
        do, dowhile,
        onerr,  //basically 'catch'
        onnull, //similar to 'orelse'

        pub fn _is(self:Keywords, check:Keywords) bool {
            return switch (check) {
                .@"if", .@"?" => self == .@"if" or self == .@"?",
                .do, .dowhile => self == .do or self == .dowhile,
                else => check == self
            };
        }
    };

    pub const Symbols = enum {
        @";",
        @"(", @")",

        @"=",
    };

    pub fn byte_looks_like_symbol(b:u8) bool {
        return byte_to_symbol(b) != null;
    }

    pub fn byte_to_symbol(b:u8) ?Symbols {
        return to_symbol(@constCast(&[_]u8{b}));
    }

    pub fn to_symbol(raw:[]u8) ?Symbols {
        return std.meta.stringToEnum(Symbols, raw);
    }

    pub fn to_keyword(raw:[]u8) ?Keywords {
        return std.meta.stringToEnum(Keywords, raw);
    }

    pub fn mk_num(comptime T:type, n:T) Token {
        return .{
            .type = .{ .number = switch (@typeInfo(T)) {
                .int => |info|
                    if (info.signedness == .signed) .{
                        .int = @intCast(n),
                    } else .{
                        .uint = @intCast(n),
                    },
                else => unreachable,
            }},
        };
    }

    pub fn make(raw:[]u8) !?Token {
        if (raw.len < 1) return null;

        if (to_symbol(raw)) |symbol|
            return .{ .type = .{ .symbol = symbol } };

        if (to_keyword(raw)) |keyword|
            return .{ .type = .{ .keyword = keyword } };

        if(raw.len > 1) {
            if (raw[0] == '$') return .{ .type = .{ .ident = .{
                .func = .{ .shell = raw[1..] }
            } } };

            if (raw[0] == '#') {
                const name =
                    if (std.mem.find(u8, raw[1..], "[")) |name_end| 
                        raw[1..name_end+1]
                    else
                        raw[1..];
                const match = std.meta.stringToEnum(Builtins, name) orelse {
                    // TODO: decide how I want to cancel the logger so this isn't clobbered
                    std.debug.print("\r\x1b[2K|{s}| -> ", .{name});
                    return error.InvalidBuiltin;
                };
                return .{ .type = .{ .ident =
                    if (Builtins.is_func(match))
                        .{ .func = .{ .builtin = match } }
                    else
                        .{ .variable = try Builtins.make_var(match, raw[1..]) }
                } };
            }

            if (raw[0] == '@') @panic("TODO: module system");

            if (raw[0] == '"' and raw[raw.len-1] == '"')
                return .{ .type = .{ .string = raw[1..raw.len-1] } };
        }

        return .{ .type = .{ .ident = .{ .unknown = raw } } };
        //return .{ .type = .{ .ident = .{ .func = .{ .local = raw } } } };
    }

    pub fn make_from_byte(b:u8) !?Token {
        return make(@constCast(&[_]u8{b}));
    }

    pub fn new(comptime T:type, value:T) Token {
        return switch (T) {
            []u8, []const u8 => .{ .type = .{ .string = value } },
            else => switch (@typeInfo(T)) {
                .Int, .Float, .ComptimeInt, .ComptimeFloat => mk_num(T, value),
                else => @compileError("unsupported type for new() helper")
            }
        };
    }

    pub fn is_variable(self:*Token) bool {
        return
            if (self.type == .ident)
                self.type.ident == .variable
            else
                false;
    }

    pub fn is_func(self:*Token) bool {
        return
            if (self.type == .ident)
                self.type.ident == .func
            else
                false;
    }
};

pub const List = struct {
    type:LegalTypes,
    value:std.ArrayList(Token.TokenType) = .empty,

    pub const LegalTypes = enum {
        string,
        bool,
        int, uint, byte,
        DYNAMIC
    };

    pub fn init(for_type:LegalTypes) List {
        return .{ .type = for_type };
    }

    pub fn append(
        self:*List,
        alloc:std.mem.Allocator,
        value:Token.TokenType
    ) !void {
        const new_type = std.meta.stringToEnum(
            LegalTypes, @tagName(value)
        ) orelse
            return error.IllegalListType;
        if (new_type != self.type or self.type == .DYNAMIC)
            return error.TypeMissmatch;
        try self.value.append(alloc, value);
    }

    pub fn count(self:*List) usize {
        return self.value.items.len;
    }

    pub fn splat(self:*List, alloc:std.mem.Allocator) ![]Token {
        var res:std.ArrayList(Token) = .empty;
        defer res.deinit(alloc);
        for (self.value.items) |entry|
            try res.append(alloc, .{ .type = entry });
        return try res.toOwnedSlice(alloc);
    }

    pub fn append_many_fat(
        self:*List,
        alloc:std.mem.Allocator,
        values:[]Token
    ) !void {
        for (values) |v|
            try self.value.append(alloc, v.type);
    }

    pub fn get_token(self:*List, i:usize) !Token {
        if (self.count() <= i) return error.IndexOutOfBounds;
        return .{ .type = self.value.items[i] };
    }

    pub const TypeCheckOpts = struct {
        solidify:bool = false,
        expected:?LegalTypes = null,
    };

    pub fn check_type(self:*List, opts:TypeCheckOpts) !void {
        if (self.value.items.len == 0) return;

        var last_type:LegalTypes = std.meta.stringToEnum(
            LegalTypes, @tagName(self.value.items[0])
        ) orelse
            return error.IllegalType;

        for (self.value.items) |value| {
            const current_type:LegalTypes = std.meta.stringToEnum(
                LegalTypes, @tagName(value)
            ) orelse
                return error.IllegalType;

            for ([_]bool{
                if (opts.expected) |expected| current_type == expected else true,
                self.type == .DYNAMIC or self.type == current_type,
                last_type == current_type,
            }) |check|
                if (!check) return error.TypeMissmatch;

            last_type = current_type;
        }

        if (opts.solidify) {
            std.debug.assert(self.type == .DYNAMIC); //should only soldify if dynamic
            self.type = last_type;
        }
    }
};
