const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("espresso.h");
    @cInclude("x.h");
    @cInclude("hdr.h");
});

export var exprs: [c.NOUTPUTS]*c.BNODE = undefined;
export var pts: [c.NPTERMS]*c.PTERM = undefined;

extern var ninputs: i32;
extern var noutputs: i32;
extern var inorder: [*]*c.Nt;
extern var outorder: [*]*c.Nt;
extern var yyfile: *c.FILE;

extern "c" fn yyparse() void;
extern "c" fn canon(*c.BNODE) *c.BNODE;
extern "c" fn read_ones(*c.BNODE, i32) *c.PTERM;
extern "c" fn cmppt(?*const anyopaque, ?*const anyopaque) i32;

pub fn eqnToTruthTable(s: [:0]const u8, writer: anytype) !void {
    const ptr = @ptrCast(?*anyopaque, @qualCast([*:0]u8, s.ptr));
    yyfile = c.fmemopen(ptr, s.len, "r");
    defer _ = c.fclose(yyfile);
    yyparse();

    var ptexprs: [c.NOUTPUTS]*c.PTERM = undefined;

    var o: i32 = 0;
    while (o < noutputs) : (o += 1) {
        const expr = &exprs[@intCast(usize, o)];
        expr.* = canon(expr.*);
        ptexprs[@intCast(usize, o)] = read_ones(expr.*, o);
    }

    var npts: i32 = 0;
    o = 0;
    while (o < noutputs) : (o += 1) {
        var pt = ptexprs[@intCast(usize, o)];
        while (true) {
            pt.index = @intCast(i16, c.ptindex(pt.ptand, ninputs));
            if (npts < c.NPTERMS) {
                pts[@intCast(usize, npts)] = pt;
                npts += 1;
            }
            if (pt.next) |next| {
                pt = next;
            } else break;
        }
    }

    try writer.print(".i {d}\n", .{ninputs});
    try writer.print(".o {d}\n", .{noutputs});
    try writer.print(".p {d}\n", .{npts});
    try writeTruthTable(&pts, npts, writer);
    try writer.writeAll(".e\n");
}

fn writeTruthTable(pterms: [*]*c.PTERM, npts: i32, writer: anytype) !void {
    c.qsort(@intToPtr(?*anyopaque, @ptrToInt(pterms)), @intCast(usize, npts), @sizeOf(*c.PTERM), cmppt);
    var i: usize = 0;
    while (i < npts) : (i += 1) {
        try writeRow(pterms[i], writer);
    }
}

fn writeRow(pterm: *c.PTERM, writer: anytype) !void {
    const inc: [3]u8 = .{ '0', '1', '-' };
    const outc: [3]u8 = .{ '0', '1', 'x' };

    var i: usize = 0;
    while (i < ninputs) : (i += 1) {
        try writer.writeByte(inc[@intCast(usize, pterm.ptand[i])]);
    }

    try writer.writeAll("  ");

    i = 0;
    while (i < noutputs) : (i += 1) {
        try writer.writeByte(outc[@intCast(usize, pterm.ptor[i])]);
    }

    try writer.writeByte('\n');
}

pub const PLA = struct {
    raw_pla: c.pPLA,

    /// TODO unpack c.read_pla and re-implement with Zig.
    pub fn openPath(path: [:0]const u8) !PLA {
        const file = c.fopen(path, "r") orelse return error.NotFound;
        defer _ = c.fclose(file);
        return openStream(file);
    }

    /// TODO a hack so that I can postpone reimplementing internal espresso
    /// routines to work with memory or file descriptors rather than C streams.
    pub fn openMem(s: [:0]const u8) !PLA {
        const ptr = @ptrCast(?*anyopaque, @qualCast([*:0]u8, s.ptr));
        const memf = c.fmemopen(ptr, s.len + 1, "r");
        defer _ = c.fclose(memf);
        return openStream(memf);
    }

    fn openStream(file: *c.FILE) !PLA {
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

test "from memory" {
    const s: [:0]const u8 =
        \\.i 11
        \\.o 1
        \\.p 64
        \\1-000000001  1   
        \\1-000000011  1   
        \\1-000000101  1   
        \\1-000000111  1   
        \\1-000001001  1   
        \\1-000001011  1   
        \\1-000001101  1   
        \\1-000001111  1   
        \\1-001000001  1   
        \\1-001000011  1   
        \\1-001000101  1   
        \\1-001000111  1   
        \\1-001001001  1   
        \\1-001001011  1   
        \\1-001001101  1   
        \\1-001001111  1   
        \\1-010000001  1   
        \\1-010000011  1   
        \\1-010000101  1   
        \\1-010000111  1   
        \\1-010001001  1   
        \\1-010001011  1   
        \\1-010001101  1   
        \\1-010001111  1   
        \\1-011000001  1   
        \\1-011000011  1   
        \\1-011000101  1   
        \\1-011000111  1   
        \\1-011001001  1   
        \\1-011001011  1   
        \\1-011001101  1   
        \\1-011001111  1   
        \\1100000000-  1   
        \\1100000001-  1   
        \\1100000010-  1   
        \\1100000011-  1   
        \\1100000100-  1   
        \\1100000101-  1   
        \\1100000110-  1   
        \\1100000111-  1   
        \\1100100000-  1   
        \\1100100001-  1   
        \\1100100010-  1   
        \\1100100011-  1   
        \\1100100100-  1   
        \\1100100101-  1   
        \\1100100110-  1   
        \\1100100111-  1   
        \\1101000000-  1   
        \\1101000001-  1   
        \\1101000010-  1   
        \\1101000011-  1   
        \\1101000100-  1   
        \\1101000101-  1   
        \\1101000110-  1   
        \\1101000111-  1   
        \\1101100000-  1   
        \\1101100001-  1   
        \\1101100010-  1   
        \\1101100011-  1   
        \\1101100100-  1   
        \\1101100101-  1   
        \\1101100110-  1   
        \\1101100111-  1   
        \\.e
    ;
    const pla = try PLA.openMem(s);
    defer pla.deinit();
    const cost = try pla.minimize();
    _ = cost;
    try pla.logSolution();
}

test " full pipeline" {
    const gpa = testing.allocator;
    const s: [:0]const u8 =
        \\INORDER = a b c d e f g h i j k;
        \\OUTORDER = z;
        \\z =
        \\    (a) & (b) & (!c) & (!d) & (!e) & (!f) & (!g) & (!h) & (!i) & (!j) |
        \\    (a) & (b) & (!c) & (!d) & (!e) & (!f) & (!g) & (!h) & (!i) & (j) |
        \\    (a) & (b) & (!c) & (!d) & (!e) & (!f) & (!g) & (!h) & (i) & (!j) |
        \\    (a) & (b) & (!c) & (!d) & (!e) & (!f) & (!g) & (!h) & (i) & (j) |
        \\    (a) & (b) & (!c) & (!d) & (!e) & (!f) & (!g) & (h) & (!i) & (!j) |
        \\    (a) & (b) & (!c) & (!d) & (!e) & (!f) & (!g) & (h) & (!i) & (j) |
        \\    (a) & (b) & (!c) & (!d) & (!e) & (!f) & (!g) & (h) & (i) & (!j) |
        \\    (a) & (b) & (!c) & (!d) & (!e) & (!f) & (!g) & (h) & (i) & (j) |
        \\    (a) & (b) & (!c) & (!d) & (e) & (!f) & (!g) & (!h) & (!i) & (!j) |
        \\    (a) & (b) & (!c) & (!d) & (e) & (!f) & (!g) & (!h) & (!i) & (j) |
        \\    (a) & (b) & (!c) & (!d) & (e) & (!f) & (!g) & (!h) & (i) & (!j) |
        \\    (a) & (b) & (!c) & (!d) & (e) & (!f) & (!g) & (!h) & (i) & (j) |
        \\    (a) & (b) & (!c) & (!d) & (e) & (!f) & (!g) & (h) & (!i) & (!j) |
        \\    (a) & (b) & (!c) & (!d) & (e) & (!f) & (!g) & (h) & (!i) & (j) |
        \\    (a) & (b) & (!c) & (!d) & (e) & (!f) & (!g) & (h) & (i) & (!j) |
        \\    (a) & (b) & (!c) & (!d) & (e) & (!f) & (!g) & (h) & (i) & (j) |
        \\    (a) & (b) & (!c) & (d) & (!e) & (!f) & (!g) & (!h) & (!i) & (!j) |
        \\    (a) & (b) & (!c) & (d) & (!e) & (!f) & (!g) & (!h) & (!i) & (j) |
        \\    (a) & (b) & (!c) & (d) & (!e) & (!f) & (!g) & (!h) & (i) & (!j) |
        \\    (a) & (b) & (!c) & (d) & (!e) & (!f) & (!g) & (!h) & (i) & (j) |
        \\    (a) & (b) & (!c) & (d) & (!e) & (!f) & (!g) & (h) & (!i) & (!j) |
        \\    (a) & (b) & (!c) & (d) & (!e) & (!f) & (!g) & (h) & (!i) & (j) |
        \\    (a) & (b) & (!c) & (d) & (!e) & (!f) & (!g) & (h) & (i) & (!j) |
        \\    (a) & (b) & (!c) & (d) & (!e) & (!f) & (!g) & (h) & (i) & (j) |
        \\    (a) & (b) & (!c) & (d) & (e) & (!f) & (!g) & (!h) & (!i) & (!j) |
        \\    (a) & (b) & (!c) & (d) & (e) & (!f) & (!g) & (!h) & (!i) & (j) |
        \\    (a) & (b) & (!c) & (d) & (e) & (!f) & (!g) & (!h) & (i) & (!j) |
        \\    (a) & (b) & (!c) & (d) & (e) & (!f) & (!g) & (!h) & (i) & (j) |
        \\    (a) & (b) & (!c) & (d) & (e) & (!f) & (!g) & (h) & (!i) & (!j) |
        \\    (a) & (b) & (!c) & (d) & (e) & (!f) & (!g) & (h) & (!i) & (j) |
        \\    (a) & (b) & (!c) & (d) & (e) & (!f) & (!g) & (h) & (i) & (!j) |
        \\    (a) & (b) & (!c) & (d) & (e) & (!f) & (!g) & (h) & (i) & (j) |
        \\    (a) & (k) & (!c) & (!d) & (!e) & (!f) & (!g) & (!h) & (!i) & (!j) |
        \\    (a) & (k) & (!c) & (!d) & (!e) & (!f) & (!g) & (!h) & (!i) & (j) |
        \\    (a) & (k) & (!c) & (!d) & (!e) & (!f) & (!g) & (!h) & (i) & (!j) |
        \\    (a) & (k) & (!c) & (!d) & (!e) & (!f) & (!g) & (!h) & (i) & (j) |
        \\    (a) & (k) & (!c) & (!d) & (!e) & (!f) & (!g) & (h) & (!i) & (!j) |
        \\    (a) & (k) & (!c) & (!d) & (!e) & (!f) & (!g) & (h) & (!i) & (j) |
        \\    (a) & (k) & (!c) & (!d) & (!e) & (!f) & (!g) & (h) & (i) & (!j) |
        \\    (a) & (k) & (!c) & (!d) & (!e) & (!f) & (!g) & (h) & (i) & (j) |
        \\    (a) & (k) & (!c) & (!d) & (e) & (!f) & (!g) & (!h) & (!i) & (!j) |
        \\    (a) & (k) & (!c) & (!d) & (e) & (!f) & (!g) & (!h) & (!i) & (j) |
        \\    (a) & (k) & (!c) & (!d) & (e) & (!f) & (!g) & (!h) & (i) & (!j) |
        \\    (a) & (k) & (!c) & (!d) & (e) & (!f) & (!g) & (!h) & (i) & (j) |
        \\    (a) & (k) & (!c) & (!d) & (e) & (!f) & (!g) & (h) & (!i) & (!j) |
        \\    (a) & (k) & (!c) & (!d) & (e) & (!f) & (!g) & (h) & (!i) & (j) |
        \\    (a) & (k) & (!c) & (!d) & (e) & (!f) & (!g) & (h) & (i) & (!j) |
        \\    (a) & (k) & (!c) & (!d) & (e) & (!f) & (!g) & (h) & (i) & (j) |
        \\    (a) & (k) & (!c) & (d) & (!e) & (!f) & (!g) & (!h) & (!i) & (!j) |
        \\    (a) & (k) & (!c) & (d) & (!e) & (!f) & (!g) & (!h) & (!i) & (j) |
        \\    (a) & (k) & (!c) & (d) & (!e) & (!f) & (!g) & (!h) & (i) & (!j) |
        \\    (a) & (k) & (!c) & (d) & (!e) & (!f) & (!g) & (!h) & (i) & (j) |
        \\    (a) & (k) & (!c) & (d) & (!e) & (!f) & (!g) & (h) & (!i) & (!j) |
        \\    (a) & (k) & (!c) & (d) & (!e) & (!f) & (!g) & (h) & (!i) & (j) |
        \\    (a) & (k) & (!c) & (d) & (!e) & (!f) & (!g) & (h) & (i) & (!j) |
        \\    (a) & (k) & (!c) & (d) & (!e) & (!f) & (!g) & (h) & (i) & (j) |
        \\    (a) & (k) & (!c) & (d) & (e) & (!f) & (!g) & (!h) & (!i) & (!j) |
        \\    (a) & (k) & (!c) & (d) & (e) & (!f) & (!g) & (!h) & (!i) & (j) |
        \\    (a) & (k) & (!c) & (d) & (e) & (!f) & (!g) & (!h) & (i) & (!j) |
        \\    (a) & (k) & (!c) & (d) & (e) & (!f) & (!g) & (!h) & (i) & (j) |
        \\    (a) & (k) & (!c) & (d) & (e) & (!f) & (!g) & (h) & (!i) & (!j) |
        \\    (a) & (k) & (!c) & (d) & (e) & (!f) & (!g) & (h) & (!i) & (j) |
        \\    (a) & (k) & (!c) & (d) & (e) & (!f) & (!g) & (h) & (i) & (!j) |
        \\    (a) & (k) & (!c) & (d) & (e) & (!f) & (!g) & (h) & (i) & (j)
        \\;
    ;

    var tt = std.ArrayList(u8).init(gpa);
    defer tt.deinit();
    try eqnToTruthTable(s, tt.writer());
    try tt.append(0);

    const pla = try PLA.openMem(tt.items[0 .. tt.items.len - 1 :0]);
    defer pla.deinit();
    const cost = try pla.minimize();
    _ = cost;
    try pla.logSolution();
}
