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

    pub fn minimize(pla: PLA, gpa: Allocator) !void {
        _ = gpa;

        const fold = c.sf_save(pla.raw_pla.*.F);
        errdefer {
            pla.raw_pla.*.F = fold;
            _ = c.check_consistency(pla.raw_pla);
        }

        pla.raw_pla.*.F = c.espresso(pla.raw_pla.*.F, pla.raw_pla.*.D, pla.raw_pla.*.R);

        var cost: c.cost_t = undefined;
        try pla.execute(fold, &cost);
        c.free_cover(fold);
    }

    /// EXECUTE(err = verify(PLA->F, fold, PLA->D), VERIFY_TIME, PLA->F, cost);
    fn execute(pla: PLA, fold: c.pset_family, cost: *c.cost_t) !void {
        var t = c.ptime();
        const err = c.verify(pla.raw_pla.*.F, fold, pla.raw_pla.*.D);
        c.totals(t, c.VERIFY_TIME, pla.raw_pla.*.F, cost);
        if (err > 0) {
            std.log.err("execute failed with errno: {d}", .{err});
            return error.ExecuteFailed;
        }
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
};

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    const filename = "example.in";
    const pla = try PLA.openPath(filename);
    defer pla.deinit();
    try pla.minimize(testing.allocator);
}
