const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("espresso.h");
});

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
    const res = c.espresso(null, null, null);
    try testing.expect(res == null);
}
