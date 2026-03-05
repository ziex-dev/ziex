<style>
body {
  display: flex;
  justify-content: center;
  align-items: center;
  height: 100vh;
  background-color: #f0f0f0;
  margin: 0;
}
#wrapper {
  width: 960px;
  height: 720px;
  position: relative;
  background-color: white;
}
.tile {
  position: absolute;
  width: 10px;
  height: 10px;
  background-color: #333;
}
</style>
<div id="root">
  <div id="wrapper">
@zig {
    const wrapper_width: f32 = 960.0;
    const wrapper_height: f32 = 720.0;
    const cell_size: f32 = 10.0;
    const center_x = wrapper_width / 2.0;
    const center_y = wrapper_height / 2.0;
    const step = cell_size;

    var angle: f32 = 0.0;
    var radius: f32 = 0.0;

    while (radius < @min(wrapper_width, wrapper_height) / 2.0) {
        const x = center_x + @cos(angle) * radius;
        const y = center_y + @sin(angle) * radius;

        if (x >= 0.0 and x <= wrapper_width - cell_size and y >= 0.0 and y <= wrapper_height - cell_size) {
            const xi: i32 = @intFromFloat(x);
            const yi: i32 = @intFromFloat(y);
            <div class="tile" style="left: {{xi}}px; top: {{yi}}px"></div>
        }

        angle += 0.2;
        radius += step * 0.015;
    }
}
  </div>
</div>
