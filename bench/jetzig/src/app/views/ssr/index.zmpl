<main>
@zig {
    const arr: [50]u32 = @splat(1);
    for (arr, 0..) |v, i| {
        <div>SSR {{v}}-{{i}}</div>
    }
}
</main>
