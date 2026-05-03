const std = @import("std");
const types = @import("types.zig");

const Token = types.Token;
const Variable = types.Variable;
const Block = types.Block;

pub fn main(init:std.process.Init) !void {
    // FIXME: deinit seg-faults
    //   defer _ = init.arena.deinit();

    const alloc = init.arena.allocator();

    var args = init.minimal.args;
    const file_name = blk: {
        var itr = try args.iterateAllocator(alloc);
        defer itr.deinit();
        _ = itr.skip();
        const ValidArgs = enum {
            run // TODO: maybe 'build'
        };
        while (itr.next()) |arg| {
            const match = std.meta.stringToEnum(ValidArgs, arg) orelse {
                std.debug.print("invalid arg: {s}\n", .{arg});
                std.process.abort();
            };
            switch (match) {
                .run => break :blk try alloc.dupe(u8, itr.next() orelse {
                    std.debug.print("no file given\n", .{});
                    std.process.abort();
                    unreachable;
                }),
            }
        }
        std.debug.print("no file given\n", .{});
        std.process.abort();
        unreachable;
    };

    var file = try std.Io.Dir.cwd().openFile(
        init.io, file_name, .{ .mode = .read_only }
    );
    defer file.close(init.io);
    var file_buf:[1024]u8 = undefined;
    var file_reader = file.reader(init.io, &file_buf);
    const reader = &file_reader.interface;

    var tokenizer:@import("tokenizer.zig").Tokenizer = try .init(alloc);
    var tokens = try tokenizer.do(reader, null);

    var finalizer:@import("finalizer.zig").Finalizer = try .init(alloc);
    _ = try finalizer.do(&tokens);

    var interpreter:@import("interpreter.zig").Interpreter = try .init(init.io, alloc);
    _ = try interpreter.do(init.minimal, tokens);
}
