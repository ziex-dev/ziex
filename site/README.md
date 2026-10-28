# Ziex App

>This is a starter template for building web applications with [Ziex](https://ziex.dev), a full-stack web framework for Zig.

**[Documentation →](https://ziex.dev)**

## Getting Started

### 1. Install Ziex CLI

#### Linux/macOS
```bash
curl -fsSL https://ziex.dev/install | bash
```

#### Windows
```powershell
powershell -c "irm ziex.dev/install.ps1 | iex"
```

### 2. Install Zig
```bash
brew install zig # macOS
winget install -e --id zig.zig # Windows
```
[_Other platforms →_](https://ziglang.org/learn/getting-started/)


## Project

```
├── app/
│   ├── assets/         # Static assets (CSS, images, etc)
│   ├── main.zig        # Zig entrypoint
│   ├── pages/          # Pages (Zig/ZX)
│   │   ├── layout.zx   # Root layout
│   │   ├── page.zx     # Home page
│   │   ├── client.zx   # Client side counter component
│   │   └── ...
│   └── public/         # Public static files (favicon, etc)
├── build.zig           # Zig build script
├── build.zig.zon       # Zig package manager config
└── README.md           # Project info
```

## Usage

### Development
```bash
zig build dev
```
App will be available at [`http://localhost:3000`](http://localhost:3000). with hot reload enabled.

### Serve Production Build
```bash
zig build serve --release=fast
```

### Exporting as Static Site
```bash
zig build zx -- build --static
```
This will create a `dist/` directory with the static export of your app. You can deploy the contents of `dist/` to any static hosting provider (Netlify, Vercel, GitHub Pages, etc) or serve it with any static file server.

### Deployment

```bash
zig build zx -- bundle
```

This will create a `bundle/` directory with the binary and static assets needed to run your app. You can deploy the contents of `bundle/` to any VPS.


### [Ziex CLI](https://ziex.dev/reference#cli) Commands
```bash
zig build zx -- [command] [options]
```

All Ziex CLI commands are available under `zig build zx -- [command]`. For example, to run auto formatter:
```bash
zig build zx -- fmt .
```

## Contributing

Contributions are welcome! Feel free to open issues or pull requests. For feature requests, bug reports, or questions, see the [Ziex Repo](https://github.com/ziex-dev/ziex).

## Links

- [Documentation](https://ziex.dev)
- [Discord](https://ziex.dev/r/discord)
- [Topic on Ziggit](https://ziex.dev/r/ziggit)
- [Project on Zig Discord Community](https://ziex.dev/r/zig-discord) (Join Zig Discord first: https://discord.gg/zig)
- [GitHub](https://github.com/nurulhudaapon/ziex)
- [Zig Language](https://ziglang.org/)