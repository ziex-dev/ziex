// Make import of .zig files work in TypeScript
declare module "*.zig" {
    const content: string;
    export default content;
}
declare module "*.zx" {
    const content: string;
    export default content;
}
declare module "*.css" {
    const content: string;
    export default content;
}

declare module "*.wasm?module" {
    const module: WebAssembly.Module;
    export default module;
}

declare module "*.wasm" {
    const module: WebAssembly.Module;
    export default module;
}

// Plain browser scripts from the branding repo, aliased in build.zig and imported for side effects
declare module "@branding/*";
