test "valid element" {
    const allocator = std.testing.allocator;

    const source: [:0]const u8 =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    return (<div>Hello</div>);
        \\}
        \\const zx = @import("zx");
    ;

    var parse_result = try Parser.parse(allocator, source, .zx);
    defer parse_result.deinit(allocator);

    var diags = try check.validate(allocator, &parse_result);
    defer diags.deinit();

    try testing.expectEqual(0, diags.items.len);
    try testing.expect(!diags.hasErrors());
}

test "valid fragment" {
    const allocator = std.testing.allocator;

    const source: [:0]const u8 =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    return (<><span>a</span><span>b</span></>);
        \\}
        \\const zx = @import("zx");
    ;

    var parse_result = try Parser.parse(allocator, source, .zx);
    defer parse_result.deinit(allocator);

    var diags = try check.validate(allocator, &parse_result);
    defer diags.deinit();

    try testing.expectEqual(0, diags.items.len);
    try testing.expect(!diags.hasErrors());
}

test "valid expression block" {
    const allocator = std.testing.allocator;

    const source: [:0]const u8 =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    const name = "world";
        \\    return (<p>Hello {name}!</p>);
        \\}
        \\const zx = @import("zx");
    ;

    var parse_result = try Parser.parse(allocator, source, .zx);
    defer parse_result.deinit(allocator);

    var diags = try check.validate(allocator, &parse_result);
    defer diags.deinit();

    try testing.expectEqual(0, diags.items.len);
}

test "unclosed tag" {
    const allocator = std.testing.allocator;

    // Missing closing </div>
    const source: [:0]const u8 =
        \\(<div>)
    ;

    var parse_result = try Parser.parse(allocator, source, .zx);
    defer parse_result.deinit(allocator);

    var diags = try check.validate(allocator, &parse_result);
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    try testing.expect(diags.items.len > 0);
    try testing.expectEqual(check.Severity.err, diags.items[0].severity);
}

test "mismatched tags" {
    const allocator = std.testing.allocator;

    const source: [:0]const u8 =
        \\(<div></span>)
    ;

    var parse_result = try Parser.parse(allocator, source, .zx);
    defer parse_result.deinit(allocator);

    var diags = try check.validate(allocator, &parse_result);
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    try testing.expect(diags.items.len > 0);
}

test "diagnostic position" {
    const allocator = std.testing.allocator;

    // Introduce an error on line 2, column 5
    const source: [:0]const u8 =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    return (<div>);
        \\}
        \\const zx = @import("zx");
    ;

    var parse_result = try Parser.parse(allocator, source, .zx);
    defer parse_result.deinit(allocator);

    var diags = try check.validate(allocator, &parse_result);
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    // Positions are 0-based.
    try testing.expect(diags.items[0].start_line >= 0);
    try testing.expect(diags.items[0].end_line >= diags.items[0].start_line);
}

test "diagnostic message" {
    const allocator = std.testing.allocator;

    const source: [:0]const u8 =
        \\(<div>)
    ;

    var parse_result = try Parser.parse(allocator, source, .zx);
    defer parse_result.deinit(allocator);

    var diags = try check.validate(allocator, &parse_result);
    defer diags.deinit();

    try testing.expect(diags.items.len > 0);
    try testing.expect(diags.items[0].message.len > 0);
}

test "broken line scope" {
    const allocator = std.testing.allocator;

    const source: [:0]const u8 =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    const broken = ;
        \\    return (<div>Hello</div>);
        \\}
        \\const zx = @import("zx");
    ;

    var parse_result = try Parser.parse(allocator, source, .zx);
    defer parse_result.deinit(allocator);

    var diags = try check.validate(allocator, &parse_result);
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    try testing.expect(diags.items.len > 0);

    const last_line: u32 = 4;
    try testing.expectEqual(@as(u32, 1), diags.items[0].start_line);
    try testing.expect(diags.items[0].end_line < last_line);
}

test "ast > parse valid" {
    const allocator = std.testing.allocator;

    const source: [:0]const u8 =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    return (<p>OK</p>);
        \\}
        \\const zx = @import("zx");
    ;

    var result = try lang.Ast.parse(allocator, source, .{});
    defer result.deinit(allocator);

    try testing.expect(!result.diagnostics.hasErrors());
    try testing.expectEqual(0, result.diagnostics.items.len);
}

test "ast > parse invalid" {
    const allocator = std.testing.allocator;

    const source: [:0]const u8 =
        \\(<div>)
    ;

    var result = try lang.Ast.parse(allocator, source, .{});
    defer result.deinit(allocator);

    try testing.expect(result.diagnostics.hasErrors());
    try testing.expect(result.diagnostics.items.len > 0);
}

test "ast > fmt valid" {
    const allocator = std.testing.allocator;

    const source: [:0]const u8 =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    return (<p>Hello</p>);
        \\}
        \\const zx = @import("zx");
    ;

    var result = try lang.Ast.fmt(allocator, source);
    defer result.deinit(allocator);

    try testing.expect(!result.diagnostics.hasErrors());
    try testing.expect(result.source != null);
}

test "ast > fmt invalid" {
    const allocator = std.testing.allocator;

    const source: [:0]const u8 =
        \\(<div>)
    ;

    var result = try lang.Ast.fmt(allocator, source);
    defer result.deinit(allocator);

    try testing.expect(result.source == null);
    try testing.expect(result.diagnostics.hasErrors());
    try testing.expect(result.diagnostics.items.len > 0);
}

test "has errors empty" {
    const allocator = std.testing.allocator;

    const source: [:0]const u8 =
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    return (<span>ok</span>);
        \\}
        \\const zx = @import("zx");
    ;

    var parse_result = try Parser.parse(allocator, source, .zx);
    defer parse_result.deinit(allocator);

    var diags = try check.validate(allocator, &parse_result);
    defer diags.deinit();

    try testing.expect(!diags.hasErrors());
}

fn validateSource(allocator: std.mem.Allocator, source: [:0]const u8) !check.DiagnosticList {
    var parse_result = try Parser.parse(allocator, source, .zx);
    defer parse_result.deinit(allocator);
    return check.validate(allocator, &parse_result);
}

fn countWithMessage(diags: check.DiagnosticList, needle: []const u8) usize {
    var n: usize = 0;
    for (diags.items) |d| {
        if (std.mem.find(u8, d.message, needle) != null) n += 1;
    }
    return n;
}

fn hasMessage(diags: check.DiagnosticList, needle: []const u8) bool {
    return countWithMessage(diags, needle) > 0;
}

test "sema > invalid html tag name" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<blah>hi</blah>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    try testing.expect(hasMessage(diags, "not a valid HTML element"));
}

test "sema > known elements are valid" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div><p>ok</p><span>x</span></div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "sema > svg elements are valid" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="4" /><path d="M0 0h10" /><g><rect width="1" height="1" /></g></svg>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "sema > svg camel case elements are valid" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<svg><clipPath id="c"><circle cx="0" cy="0" r="1" /></clipPath><linearGradient id="g"><stop offset="0" /></linearGradient></svg>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "sema > components are not html-validated" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div><Foo /><ns.Bar /></div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(!diags.hasErrors());
    try testing.expect(!hasMessage(diags, "not a valid HTML element"));
}

test "sema > custom-element and component classification" {
    // Hyphenated custom elements and namespaced/uppercase components are not
    // subject to HTML element-name validation. (Tested directly because the
    // ZX grammar does not yet parse hyphenated tag names inline.)
    try testing.expect(check.elements.isCustomOrComponent("my-widget"));
    try testing.expect(check.elements.isCustomOrComponent("Foo"));
    try testing.expect(check.elements.isCustomOrComponent("ns.Bar"));
    try testing.expect(check.elements.isCustomOrComponent("fragment"));
    try testing.expect(!check.elements.isCustomOrComponent("div"));
    try testing.expect(!check.elements.isCustomOrComponent("blah"));
}

test "sema > fragment is not html-validated" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<fragment><p>a</p></fragment>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(!diags.hasErrors());
}

test "sema > deprecated element" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<center>old</center>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    try testing.expect(hasMessage(diags, "deprecated and unsupported"));
}

test "sema > html element cannot self-close" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div><span /></div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    try testing.expect(hasMessage(diags, "can't self-close"));
}

test "sema > void element self-close is allowed" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div><br /><img src="x.png" /><hr /></div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(!diags.hasErrors());
    try testing.expect(!hasMessage(diags, "can't self-close"));
}

test "sema > void element with end tag" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div><br>x</br></div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(hasMessage(diags, "void elements have no end tag"));
}

test "sema > duplicate attribute is a warning" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div class="a" class="b">x</div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(hasMessage(diags, "duplicate attribute"));
    // Warnings must not block formatting/compilation.
    try testing.expect(!diags.hasErrors());
}

test "sema > duplicate id is a warning" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div id="x"><span id="x">y</span></div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(hasMessage(diags, "duplicate id"));
    try testing.expect(!diags.hasErrors());
}

test "sema > distinct ids are fine" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div id="x"><span id="y">z</span></div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(!hasMessage(diags, "duplicate id"));
}

test "sema > unknown builtin attribute" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div @notARealBuiltin={a}>x</div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    try testing.expect(hasMessage(diags, "unknown ZX builtin attribute"));
}

test "sema > known builtin attribute is fine" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div @allocator={a}><Counter @client /></div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(!hasMessage(diags, "unknown ZX builtin attribute"));
}

test "sema > @client takes no value" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div @allocator={a}><Counter @client={.client} /></div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    try testing.expect(hasMessage(diags, "'@client' takes no value"));
}

test "sema > valued builtin without a value" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div @allocator={a} @escaping>x</div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    try testing.expect(hasMessage(diags, "'@escaping' needs a value"));
}

test "sema > @rendering points to @client" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div @allocator={a}><Counter @rendering={.client} /></div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    try testing.expect(hasMessage(diags, "'@rendering' was replaced by '@client'"));
}

test "sema > @client has no shorthand" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator, client: bool) zx.Component {
        \\    _ = client;
        \\    return (<div @allocator={a}><Counter @{client} /></div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(hasMessage(diags, "unknown ZX builtin attribute"));
}

test "sema > unknown builtin shorthand" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div @{notARealBuiltin}>x</div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    try testing.expect(hasMessage(diags, "unknown ZX builtin attribute"));
}

test "sema > known builtin shorthand is fine" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(allocator: zx.Allocator) zx.Component {
        \\    return (<div @{allocator}>x</div>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expect(!hasMessage(diags, "unknown ZX builtin attribute"));
}

test "visibility > @client component must be pub" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (<div @allocator={a}><Counter @client /><Label @client /></div>);
        \\}
        \\fn Counter(ctx: *zx.ComponentContext) zx.Component {
        \\    return (<p @allocator={ctx.allocator}>0</p>);
        \\}
        \\pub fn Label(ctx: *zx.ComponentContext) zx.Component {
        \\    return (<p @allocator={ctx.allocator}>x</p>);
        \\}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expectEqual(1, countWithMessage(diags, "is a @client component and must be `pub`"));
    try testing.expect(hasMessage(diags, "'Counter' is a @client component"));
}

test "visibility > bound server handlers must be pub" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(ctx: *zx.ComponentContext) zx.Component {
        \\    return (
        \\        <div @allocator={ctx.allocator}>
        \\            <button onclick={ctx.bind(onSave)}>a</button>
        \\            <button onclick={ctx.bind(&onSave)}>b</button>
        \\            <button onclick={ctx.sbind(onInc, .{})}>c</button>
        \\            <form action={ctx.action(onSubmit, .{})}></form>
        \\            <form action={ctx.bind(onTyped)}></form>
        \\            <button onclick={ctx.bind(onPub)}>d</button>
        \\        </div>
        \\    );
        \\}
        \\fn onSave(_: *zx.server.Event) void {}
        \\fn onInc(_: *Event.Stateful) void {}
        \\fn onSubmit(_: *zx.server.Action.Stateful) void {}
        \\fn onTyped(_: Input, _: *zx.StateContext) void {}
        \\pub fn onPub(_: *zx.server.Event) void {}
        \\const Input = struct { name: []const u8 };
        \\const Event = zx.server.Event;
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    // One report per handler, however often it is bound.
    try testing.expectEqual(4, countWithMessage(diags, "must be `pub` to be registered"));
    try testing.expect(hasMessage(diags, "'onSave'"));
    try testing.expect(hasMessage(diags, "'onInc'"));
    try testing.expect(hasMessage(diags, "'onSubmit'"));
    try testing.expect(hasMessage(diags, "'onTyped'"));
    try testing.expect(!hasMessage(diags, "'onPub'"));
}

test "visibility > direct action attribute" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(a: zx.Allocator) zx.Component {
        \\    return (
        \\        <div @allocator={a}>
        \\            <form action={onLogin}></form>
        \\            <form action={onClientForm}></form>
        \\            <button onclick={onServer}>s</button>
        \\        </div>
        \\    );
        \\}
        \\fn onLogin(_: LoginInput) void {}
        \\fn onClientForm(_: zx.client.Action) void {}
        \\fn onServer(_: zx.server.Event) void {}
        \\const LoginInput = struct { name: []const u8 };
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expectEqual(2, countWithMessage(diags, "must be `pub` to be registered"));
    try testing.expect(hasMessage(diags, "'onLogin'"));
    try testing.expect(hasMessage(diags, "'onServer'"));
}

test "visibility > client handlers may stay private" {
    const allocator = std.testing.allocator;
    var diags = try validateSource(allocator,
        \\pub fn Page(ctx: *zx.ComponentContext) zx.Component {
        \\    return (
        \\        <div @allocator={ctx.allocator}>
        \\            <button onclick={ctx.bind(onClick)}>a</button>
        \\            <form action={ctx.bind(onForm)}></form>
        \\            <input oninput={onInput} />
        \\        </div>
        \\    );
        \\}
        \\fn onClick(_: *zx.client.Event.Stateful) void {}
        \\fn onForm(_: *zx.client.Action) void {}
        \\fn onInput(_: zx.client.Event) void {}
        \\const zx = @import("zx");
    );
    defer diags.deinit();

    try testing.expectEqual(0, diags.items.len);
}

test "sema > skipped when syntax errors present" {
    const allocator = std.testing.allocator;
    // Unknown tag <blah> would normally be flagged, but the unclosed tag is a
    // syntax error, so the semantic pass is skipped to avoid cascading noise.
    var diags = try validateSource(allocator, "(<blah>)");
    defer diags.deinit();

    try testing.expect(diags.hasErrors());
    try testing.expect(!hasMessage(diags, "not a valid HTML element"));
}

const std = @import("std");
const testing = std.testing;
const zx = @import("zx");
const lang = @import("lang");
const Parser = lang.Parse;
const check = lang.Ast.check;
