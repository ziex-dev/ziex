<p align="center">
    <img src="https://raw.githubusercontent.com/ziex-dev/branding/main/banner-animated.svg" alt="Ziex banner" width="100%" />
</p>

A full-stack web framework for Zig. Declarative UI components using familiar patterns, with full access to Zig's control flow.

Ziex combines the power and performance of Zig with the expressiveness and simplicity of declarative UI, enabling you to build fast, type-safe web applications.


> **Note:** Most of the API and syntax are finalized and stable, and server-side rendering (SSR) features are production-ready, Ziex continues to evolve with ongoing improvements to client-side rendering and state management, see the [roadmap](#roadmap). You can start using the documented features today, as they are stable and unlikely to change. Areas still under development are not yet documented and will be added as they mature. See [versions](#versions) for Zig and Ziex versions compatibility.

**[Documentation →](https://ziex.dev/learn)**

## Getting Started

### 1. Installing CLI (optional)

```bash
# macOS/Linux
curl -fsSL https://ziex.dev/install | bash

# Windows
powershell -c "irm ziex.dev/install.ps1 | iex"
```


### 2. Initializing Project

```powershell
zx init
# or
npm init ziex
# or
git clone https://github.com/ziex-dev/template-starter my-app
cd my-app && zig build dev
```

You will need [compatible](#versions) Zig version when using zx CLI or you can use the `Node` template from `npm init ziex`

Read [Getting Started →](https://ziex.dev/learn) for more details.

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

Try this in [Playground →](https://ziex.dev/playground#data=eF59U01vnDAQ_StTTtAiyGZVqSKAEuVSVa2USy8NUUTAu2sJbGQgoUv83ztjlo-y2_rCfLx5zMyze-uhSH_vlWxF7h07K7Cq9gV2AuawnRaFzNJGqgCOnXc3eg5597KspGCigT4RgCeTom6A18-FTHMu9hBBo1p2M2RfUwU8gLbmR4aZKwwPCcWaVgmwB49OWKZcwO3086ifTB3PMAM9bOKvDLMu_OKs-xD6GBiZx9PvpAK7rZmqHXin7_vydxPXg5I7XjAQacminnAemRrS_eijpUHJYvTJ1OCvunL0WQt8B_a8GgfssIq_D47neaFfxQ6womZTguUmeM70dqAebQ4hfHYgIOtTBBui5HHPdehzUzYWhD6t89Shg2s3lKTzMK6dNV0AH5eK3jed_RPHcy4LfUGxnL_-JRhyev8RbRsbRKVkVQ87RuG2axiSLnG0-9Cn4ApXN0qK_SpKp6_feJMdwJ5JSDBnHGR9vDQv8eZFMSTWHZmJ5f4DWbLyhakB-sPYF7Far3r1z5pdjjTJM7wl0gDfCpa0GW7fXMwAHp-GbPvFpZuJb2p77ZpLGQATbYlAM4cLpyY16JuZ1LwDZH18fiL-0yq8HowQmEisb_JAowOtHAPXV2gSP9qnFWn3Ulkq2LJssygbW8G6ZTPHDpO3HC-YauzEOnaJRTuw9B927V4U)

<details>
<summary>Explanation of this</summary>

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
// - `pub fn ComponentName(ctx: *zx.ComponentCtx(PropsType)) zx.Component`
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

- **Declarative UI**: Declarative UI components using with full access to Zig's control flow.
- **Full-Stack Capabilities**: Build both frontend and backend of web application.
- **Fast**: Significantly faster at SSR than many other frameworks.
- **Familiar Syntax**: Familiar JSX-like syntax, or plain HTML-style markup, with full access to Zig's control flow.
- **Server-side Rendering**: Render per request on the server for dynamic data, auth, and personalized pages for best performance and SEO.
- **Static Site Generation**: Pre-render pages at build/export time into static HTML for fast CDN delivery.
- **File System Routing**: Folder structure defines routes.
- **Client-side Rendering**: Client-side rendering with Zig for building interactive experiences.
- **Developer Tooling**: CLI, hot reload, and editor extensions for the best DX.

## Versions

| Zig      | Ziex                                                                              | Branch     | Status      |
| -------- | --------------------------------------------------------------------------------- | ---------- | ----------- |
| `0.17.x` |                                                                                   | `main`     | Development |
| `0.17.x` | [`image.png`](https://github.com/ziex-dev/ziex/releases/tag/vimage.png)           |            | **Latest**  |
| `0.16.x` | [`0.1.0-dev.1259`](https://github.com/ziex-dev/ziex/releases/tag/v0.1.0-dev.1259) | `zig-0.16` | Outdated    |
| `0.15.x` | [`0.1.0-dev-1050`](https://github.com/ziex-dev/ziex/releases/tag/v0.1.0-dev.1050) | `zig-0.15` | Outdated    |

## Roadmap

[Ziex 0.1.0](https://github.com/ziex-dev/ziex/milestone/2) is planned for release after `Zig 0.17.0` is available. You can view the [roadmap](https://github.com/ziex-dev/ziex/milestones) to learn more.

The [`0.1.0`](https://github.com/ziex-dev/ziex/milestone/2) release will indicate that Ziex is production-ready, with all major features fully implemented, and will receive patch releases for bug fixes.

The [`1.0.0`](https://github.com/ziex-dev/ziex/milestone/6) release will signify long-term support for that major version, receiving bug fixes and minor updates.

## Community

- [Discord](https://ziex.dev/r/discord)
- [Topic on Ziggit](https://ziex.dev/r/ziggit)
- [Project on Zig Discord Community](https://ziex.dev/r/zig-discord) (Join Zig Discord first: https://discord.gg/zig)
- [Codeberg Mirror](https://codeberg.org/ziex/ziex) - Ziex repository mirror on Codeberg
- [ziex.dev](https://github.com/ziex-dev/ziex/tree/main/site) - Official documentation site of Ziex made using Ziex.

## Contributing

Contributions are welcome! Trying out Ziex, reporting issues (especially edge cases), and providing feedback are greatly appreciated. You can also look through the [open issues](https://github.com/ziex-dev/ziex/issues) to find something to work on.
