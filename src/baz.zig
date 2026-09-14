//! Baz — Bounded Async Zap. Experimental application API for exact Zig 0.16.0.
//!
//! Start with `App(Shared)` for typed routes and endpoints, or `AppWithLocals`
//! for middleware with request-local state. `Request` borrows request input;
//! `Response` builds bounded output on application workers.
//!
//! Use `Stream` and `continuation` for incremental responses, `Mailbox` for
//! bounded notifications, and `sse` for server-sent event encoding. Request,
//! response and borrowed-body storage must remain valid for their documented
//! lifetimes. Capacity and ownership rules are part of the API contract.
//!
//! The `engine` export is the same dependency module used by Baz; its types
//! retain their identity when used alongside framework types.
pub const defaultErrorStatus = @import("App.zig").defaultErrorStatus;
pub const App = @import("App.zig").App;
pub const AppWithLocals = @import("App.zig").AppWithLocals;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const sse = @import("sse.zig");
pub const Mailbox = @import("mailbox.zig").Mailbox;
pub const continuation = @import("continuation.zig");
pub const Snapshot = @import("response.zig").Snapshot;
pub const Stream = @import("response.zig").Stream;
pub const ResponseLimits = @import("response.zig").Limits;
pub const params = @import("params.zig");
pub const form = @import("form.zig");
pub const multipart = @import("multipart.zig");
pub const cookies = @import("cookies.zig");
pub const router = @import("router.zig");
pub const mustache = @import("mustache.zig");

/// Reexport the dependency's actual module. Applications can mix framework
/// and engine types without creating a second engine module identity.
pub const engine = @import("bounded_http");
pub const api = engine.api;
pub const Budget = engine.Budget;
pub const Config = engine.Config;
pub const Cluster = engine.Cluster;
pub const Server = engine.Server;
pub const Execution = engine.Execution;
pub const Stats = engine.Stats;
pub const Admission = engine.Admission;
pub const backend_name = engine.backend_name;
pub const nowNs = engine.nowNs;
