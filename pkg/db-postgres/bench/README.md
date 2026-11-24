# Postgres client benchmark

Compares `zx.Db` on Postgres (the real `src/runtime/core/Db.zig` front end over this package:
pool, placeholder rewrite, row cloning, statement cache) with
[pg.zig](https://github.com/karlseguin/pg.zig) and libpq, one connection each.

| Workload | What it measures |
|---|---|
| `connect` | open + SCRAM auth + close, 50 per run |
| `select_one` | `SELECT $1::int4 + 1`, 5000 round trips |
| `insert` | `INSERT ... VALUES ($1, $2)` into an UNLOGGED table, 5000 round trips |
| `fetch_100k` | read 100k rows (int + text) |

Each client runs in two modes:

| | zx.Db | pg.zig | libpq |
|---|---|---|---|
| unprepared | `statement_cache_size=0` | `query`/`exec` (Parse/Describe round trip, then Bind/Execute) | `PQexecParams` |
| cached / prepared | default cache | `cache_name` | `PQprepare` + `PQexecPrepared` |

Every repetition runs all drivers in turn (interleaved). Output is two tables (unprepared,
cached) of ops/s (rows/s for `fetch_100k`), median of 7, with `zx.Db vs X` ratios, plus a
table of client CPU per op (process CPU time, so it isn't hidden by network latency).

To profile one driver, `--profile <zx|pgzig> <workload> <url>` loops a cached-mode workload
for ~10s; attach `sample <pid>` (macOS) or `perf` (Linux), or wrap it in `/usr/bin/time -l`.

## Run

```sh
docker run -d --rm --name pg-bench -e POSTGRES_PASSWORD=pw -p 5432:5432 postgres:17

# libpq is optional; without -Dlibpq its rows are skipped
zig build run -Dlibpq=$(brew --prefix libpq) -- 'postgres://postgres:pw@127.0.0.1:5432/postgres?sslmode=disable'
```

### Over TLS

Add `sslmode=require` to the URL. zx.Db uses `std.crypto.tls`; libpq uses its own OpenSSL; pg.zig
needs OpenSSL linked:

```sh
zig build run -Dlibpq=$(brew --prefix libpq) -Dopenssl=$(brew --prefix openssl@3) -- \
  'postgres://postgres:pw@127.0.0.1:5432/postgres?sslmode=require'
```

The server needs `ssl=on` with a certificate; a self-signed one is fine for `require`.

Builds default to `-Doptimize=fast`. On macOS, Docker's VM network adds about 100 µs
per round trip, which hides client cost. For client-bound numbers, run inside the
server container over loopback:

```sh
zig build -Dtarget=aarch64-linux-musl --prefix /tmp/pg-bench-linux   # or x86_64-linux-musl
docker cp /tmp/pg-bench-linux/bin/pg-bench pg-bench:/tmp/pg-bench
docker exec pg-bench /tmp/pg-bench 'postgres://postgres:pw@127.0.0.1:5432/postgres?sslmode=disable'
```
