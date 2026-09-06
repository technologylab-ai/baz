/* Zig keywords match lib/std/zig/tokenizer.zig in the exact 0.16.0 release. */
hljs.registerLanguage('zig', h => ({
  name: 'Zig', keywords: {
    keyword: 'addrspace align allowzero and anyframe anytype asm break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline noalias noinline nosuspend opaque or orelse packed pub resume return linksection struct suspend switch test threadlocal try union unreachable var volatile while',
    literal: 'true false null undefined',
    type: 'bool void noreturn type anyerror anyopaque usize isize comptime_int comptime_float f16 f32 f64 f80 f128'
  }, contains: [h.C_LINE_COMMENT_MODE, h.QUOTE_STRING_MODE, h.APOS_STRING_MODE,
    {scope: 'string', begin: /\\\\/, end: /$/},
    {scope: 'built_in', begin: /@[A-Za-z_][A-Za-z_0-9]*/},
    {scope: 'type', begin: /\b[ui]\d+\b/}, h.C_NUMBER_MODE]
}));
