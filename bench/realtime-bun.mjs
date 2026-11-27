// Bun.serve mirror of site/app/pages/sandbox/api/route.zig for pub/sub benches.
const CLIENTS_TO_WAIT_FOR = parseInt(process.env.CLIENTS_COUNT || "32", 10);
const PORT = parseInt(process.env.PORT || "3001", 10);
const ROOM = "room";

let remaining = CLIENTS_TO_WAIT_FOR;

const server = Bun.serve({
  port: PORT,
  fetch(req, srv) {
    const url = new URL(req.url);
    if (url.pathname !== "/sandbox/api") return new Response("ok");
    const name = url.searchParams.get("name") || `Client`;
    const ok = srv.upgrade(req, { data: { name } });
    return ok ? undefined : new Response("upgrade failed", { status: 400 });
  },
  websocket: {
    // Match site sandbox/api: configure(.{ .publish_to_self = true })
    publishToSelf: true,
    open(ws) {
      ws.subscribe(ROOM);
      remaining -= 1;
      console.log(`${ws.data.name} connected (${remaining} remain)`);
      ws.send("connected");
      if (remaining === 0) {
        console.log("All clients connected");
        remaining = CLIENTS_TO_WAIT_FOR;
        server.publish(ROOM, "ready");
      }
    },
    message(ws, message) {
      const text = typeof message === "string" ? message : new TextDecoder().decode(message);
      ws.publish(ROOM, `${ws.data.name}: ${text}`);
    },
    close() {
      remaining += 1;
    },
  },
});

console.log(`Bun realtime bench server on ws://127.0.0.1:${PORT}/sandbox/api`);
