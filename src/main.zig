const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("espresso.h");
});

pub const PLA = struct {
    raw_pla: c.pPLA,

    /// TODO unpack c.read_pla and re-implement with Zig.
    pub fn openPath(path: [:0]const u8) !PLA {
        const file = c.fopen(path, "r") orelse return error.NotFound;
        defer _ = c.fclose(file);

        var raw_pla: c.pPLA = undefined;
        switch (c.read_pla(file, c.TRUE, c.TRUE, c.FD_type, &raw_pla)) {
            1 => {}, // success
            -1 => return error.UnexpectedEOF,
            else => |e| {
                std.log.err("unexpected errno: {d}", .{e});
                return error.UnexpectedError;
            },
        }
        raw_pla.*.filename = null; // TODO is this really needed here?

        return PLA{ .raw_pla = raw_pla };
    }

    pub fn minimize(pla: PLA) !c.cost_t {
        const fold = c.sf_save(pla.raw_pla.*.F);
        errdefer {
            pla.raw_pla.*.F = fold;
            _ = c.check_consistency(pla.raw_pla);
        }

        pla.raw_pla.*.F = c.espresso(pla.raw_pla.*.F, pla.raw_pla.*.D, pla.raw_pla.*.R);

        const ret = try execute(.@"error", c.verify, .{
            pla.raw_pla.*.F, fold, pla.raw_pla.*.D,
        }, c.VERIFY_TIME, pla.raw_pla.*.F);

        c.free_cover(fold);

        return ret.cost;
    }

    pub fn logSolution(pla: PLA) !void {
        _ = try execute(.{ .type = void }, c.fprint_pla, .{
            c.stderr, pla.raw_pla, c.FD_type,
        }, c.WRITE_TIME, pla.raw_pla.*.F);
    }

    pub fn deinit(pla: PLA) void {
        c.free_PLA(pla.raw_pla);
        if (@as(?*c_int, c.cube.part_size)) |x| {
            c.free(x);
        }
        c.setdown_cube();
        c.sf_cleanup();
        c.sm_cleanup();
    }

    const ExecuteRetType = union(enum) {
        @"error",
        type: type,
    };

    fn ExecuteResult(comptime Ret: type) type {
        return struct {
            ret: Ret,
            cost: c.cost_t,
        };
    }

    /// Encapsulation of the EXECUTE macro
    fn execute(
        comptime ret_type: ExecuteRetType,
        func: anytype,
        args: anytype,
        record_type: u8,
        s: anytype,
    ) !ExecuteResult(switch (ret_type) {
        .@"error" => void,
        .type => |t| t,
    }) {
        var cost: c.cost_t = undefined;
        var t = c.ptime();
        const ret = @call(.auto, func, args);
        c.totals(t, record_type, s, &cost);
        if (ret_type == .@"error" and ret > 0) {
            std.log.err("execute failed with errno: {d}", .{ret});
            return error.ExecuteFailed;
        }
        return ExecuteResult(switch (ret_type) {
            .@"error" => void,
            .type => |tt| tt,
        }){
            .ret = if (ret_type == .@"error") {} else ret,
            .cost = cost,
        };
    }
};

test "basic add functionality" {
    const filename = "example.in";
    const pla = try PLA.openPath(filename);
    defer pla.deinit();
    const cost = try pla.minimize();
    _ = cost;
    try pla.logSolution();
}
