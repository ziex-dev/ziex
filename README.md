# Ziex

A full-stack web framework for Zig. Write declarative UI components using familiar JSX patterns, transpiled to efficient Zig code.

Ziex combines the power and performance of Zig with the expressiveness of JSX, enabling you to build fast, type-safe web applications.

**[Documentation →](https://ziex.dev/learn)**

## Installation

##### Linux/macOS
```bash
curl -fsSL https://ziex.dev/install | bash
```

##### Windows
```powershell
powershell -c "irm ziex.dev/install.ps1 | iex"

```
##### Installing Zig
```bash
brew install zig # macOS
winget install -e --id zig.zig # Windows
```
[_See for other platforms →_](https://ziglang.org/learn/getting-started/)


## At a Glance

```tsx site/pages/examples/playground.zx
pub fn Playground(allocator: zx.Allocator) zx.Component {
    const is_loading = true;
    var i: usize = 0;

    return (
        <main @allocator={allocator}>
            <h1>Hello, Ziex!</h1>

            {for (users) |user| (
                <Profile name={user.name} age={user.age} role={user.role} />
            )}

            {if (is_loading) (<p>Loading...</p>) else (<p>Loaded</p>)}

            {while (i < 5) : (i += 1) (<i>{i}</i>)}
        </main>
    );
}

fn Profile(ctx: *zx.ComponentCtx(User)) zx.Component {
    return (
        <div @allocator={ctx.allocator}>
            <h3>{ctx.props.name}</h3>
            <div>{ctx.props.age}</div>
            <strong>
                {switch (ctx.props.role) {
                    .admin => "Admin",
                    .member => "Member",
                }}
            </strong>
        </div>
    );
}

const User = struct { name: []const u8, age: u32, role: enum { admin, member } };

const users = [_]User{
    .{ .name = "John", .age = 20, .role = .admin },
    .{ .name = "Jane", .age = 21, .role = .member },
};

const zx = @import("zx");
```

Try this in [Playground →](https://ziex.dev/playground#data=eF59U01vnDAQ_StTTtAiyGZVqSKAEuVSVa2USy8NUUTAu2sJbGQgoUv83ztjlo-y2_rCfLx5zMyze-uhSH_vlWxF7h07K7Cq9gV2AuawnRaFzNJGqgCOnXc3eg5597KspGCigT4RgCeTom6A18-FTHMu9hBBo1p2M2RfUwU8gLbmR4aZKwwPCcWaVgmwB49OWKZcwO3086ifTB3PMAM9bOKvDLMu_OKs-xD6GBiZx9PvpAK7rZmqHXin7_vydxPXg5I7XjAQacminnAemRrS_eijpUHJYvTJ1OCvunL0WQt8B_a8GgfssIq_D47neaFfxQ6womZTguUmeM70dqAebQ4hfHYgIOtTBBui5HHPdehzUzYWhD6t89Shg2s3lKTzMK6dNV0AH5eK3jed_RPHcy4LfUGxnL_-JRhyev8RbRsbRKVkVQ87RuG2axiSLnG0-9Cn4ApXN0qK_SpKp6_feJMdwJ5JSDBnHGR9vDQv8eZFMSTWHZmJ5f4DWbLyhakB-sPYF7Far3r1z5pdjjTJM7wl0gDfCpa0GW7fXMwAHp-GbPvFpZuJb2p77ZpLGQATbYlAM4cLpyY16JuZ1LwDZH18fiL-0yq8HowQmEisb_JAowOtHAPXV2gSP9qnFWn3Ulkq2LJssygbW8G6ZTPHDpO3HC-YauzEOnaJRTuw9B927V4U)!

<details>
<summary>Explanation →</summary>

```tsx site/pages/examples/playground.zx
// A Zig function that returns a `zx.Component`.
pub fn Playground(allocator: zx.Allocator) zx.Component {
    const is_loading = true;
    var i: usize = 0;

    // HTML Block is always surrounded by parentheses and can contain HTML elements and control flow statements.
    return (
        // @allocator or any other attribute starting with `@` is called builtin attribute
        // `@allocator` is used to specify the allocator for the component and its children for mem allocation.
        <main @allocator={allocator}>
            <h1>Hello, Ziex!</h1>

            // `for` loop to iterate over `users` array and render a `Profile` component for each user.
            // Since this is an expression the HTMLs are inside parenteses not curly braces.
            {for (users) |user| (
                // `Profile` component is called with props: name, age, and role.
                // Optional props can be omitted, and the component will receive default values for them.
                <Profile name={user.name} age={user.age} role={user.role} />
            )}

            // `if` statement works just like other control flow statements.
            {if (is_loading) (<p>Loading...</p>) else (<p>Loaded</p>)}

            // `while` loop with an optional increment statement.
            {while (i < 5) : (i += 1) (<i>{i}</i>)}
        </main>
    );
}

// A Ziex Component is a Zig function that returns a `zx.Component`.
// It can have signatures like:
// - `pub fn ComponentName(allocator: zx.Allocator) zx.Component`
// - `pub fn ComponentName(ctx: *zx.ComponentCtx<PropsType>) zx.Component`
// - `pub fn ComponentName(allocator: zx.Allocator, props: PropsType) zx.Component`
fn Profile(ctx: *zx.ComponentCtx(User)) zx.Component {
    return (
        <div @allocator={ctx.allocator}>
        // Exrepssion starts with `{` and ends with `}`. You can use it to access props, call functions, any valid Zig expression
            <h3>{ctx.props.name}</h3>
            <div>{ctx.props.age}</div>
            <strong>
                {switch (ctx.props.role) {
                    .admin => "Admin",
                    .member => "Member",
                }}
            </strong>
        </div>
    );
}

const User = struct { name: []const u8, age: u32, role: enum { admin, member } };

const users = [_]User{
    .{ .name = "John", .age = 20, .role = .admin },
    .{ .name = "Jane", .age = 21, .role = .member },
};

const zx = @import("zx");
```

</details>

## Features
- **JSX-like Syntax**: Write declarative UI components using familiar JSX patterns, transpiled to efficient Zig code.
- **Full-Stack Capabilities**: Build both frontend and backend of your web application using
- **It's Fast**: Significantly faster at SSR than many other frameworks.
- **Compile-time Safety**: Zig's type system catches bugs at compile time. No runtime surprises, no GC.
- **Familiar Syntax**: Familiar JSX-like syntax, or plain HTML-style markup, with full access to Zig's control flow.
- **Server-side Rendering**: Render per request on the server for dynamic data, auth, and personalized pages for best performance and SEO.
- **Static Site Generation**: Pre-render pages at build/export time into static HTML for fast CDN delivery.
- **File System Routing**: Folder structure defines routes. No configs, no magic strings, just files in folders.
- **Client-side Rendering**: Optional client-side rendering for interactive experiences when you need it.
- **Control Flow in Zig's Syntax**: if/else, for/while, and switch all work as expected. It's just Zig.
- **Developer Tooling**: CLI, hot reload, and editor extensions for the best DX.

## Roadmap

We track our feature roadmap and bugs using GitHub Issues. 
You can view our current progress and planned features here:

**[Check out the Ziex Issue Tracker →](https://github.com/ziex-dev/ziex/issues)**

## Editor Support

* [VSCode](https://marketplace.visualstudio.com/items?itemName=ziex.ziex)/[VSCode Forks](https://open-vsx.org/extension/ziex/ziex) Extension
* [Neovim](/ide/neovim/)
* [Helix](/ide/helix/)
* [Zed](/ide/zed/)

## Community

- [Discord](https://ziex.dev/r/discord)
- [Topic on Ziggit](https://ziex.dev/r/ziggit)
- [Project on Zig Discord Community](https://ziex.dev/r/zig-discord) (Join Zig Discord first: https://discord.gg/zig)


## Links

* [Codeberg Mirror](https://codeberg.org/ziex-dev/ziex) - ZX repository mirror on Codeberg
* [ziex.dev](https://github.com/ziex-dev/ziex/tree/main/site) - Official documentation site of ZX made using ZX.
* [example-blog](https://github.com/ziex-dev/example-blog) - Demo blog web application built with ZX
* [zx-numbers-game](https://github.com/Andrew-Velox/zx-numbers-game) - ZX numbers game
* [Comparision with other frameworks](https://ziex.dev/vs)

## Contributing

Contributions are welcome! Currently trying out ZX and reporting issues for edge cases and providing feedback are greatly appreciated.
