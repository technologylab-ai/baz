//! A fixed user table owns every name. Callers hold the table lock during access.
const std = @import("std");

pub const max_users = 16;
pub const max_name_bytes = 64;
pub const View = struct { id: u64, first_name: []const u8, last_name: []const u8 };
pub const User = struct {
    occupied: bool = false,
    id: u64 = 0,
    first_name: [max_name_bytes]u8 = undefined,
    first_len: usize = 0,
    last_name: [max_name_bytes]u8 = undefined,
    last_len: usize = 0,

    pub fn view(self: *const User) View {
        return .{ .id = self.id, .first_name = self.first_name[0..self.first_len], .last_name = self.last_name[0..self.last_len] };
    }

    pub fn update(self: *User, first: ?[]const u8, last: ?[]const u8) !void {
        if (first) |value| if (value.len > max_name_bytes) return error.UserNameTooLong;
        if (last) |value| if (value.len > max_name_bytes) return error.UserNameTooLong;
        if (first) |value| {
            @memcpy(self.first_name[0..value.len], value);
            self.first_len = value.len;
        }
        if (last) |value| {
            @memcpy(self.last_name[0..value.len], value);
            self.last_len = value.len;
        }
    }
};

pub const Store = struct {
    lock: std.Io.Mutex = .init,
    users: [max_users]User = @splat(.{}),
    next_id: u64 = 1,

    pub fn add(self: *Store, first: []const u8, last: []const u8) !u64 {
        for (&self.users) |*slot| {
            if (slot.occupied) continue;
            const next = std.math.add(u64, self.next_id, 1) catch return error.UserCapacityReached;
            var value: User = .{ .occupied = true, .id = self.next_id };
            try value.update(first, last);
            slot.* = value;
            self.next_id = next;
            return value.id;
        }
        return error.UserCapacityReached;
    }

    pub fn get(self: *Store, id: u64) ?*User {
        for (&self.users) |*user| if (user.occupied and user.id == id) return user;
        return null;
    }

    pub fn remove(self: *Store, id: u64) bool {
        const user = self.get(id) orelse return false;
        user.* = .{};
        return true;
    }
};
