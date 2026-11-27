# MySQL client benchmark

Compares `zx.Db` on MySQL (the real `src/runtime/core/Db.zig` front end over this package:
pool, placeholder handling, row cloning, statement cache) with libmysqlclient, one connection each.

| Workload | What it measures |
|---|---|
| `connect` | open + handshake/auth + close, 50 per run |
| `select_one` | `SELECT ? + 1`, 5000 round trips |
| `insert` | `INSERT ... VALUES (?, ?)`, 5000 round trips |
| `fetch_100k` | read 100k rows (int + text) from a fixture table |

Each client runs in two modes:

| | zx.Db | libmysql |
|---|---|---|
| unprepared | `statement_cache_size=0` (COM_STMT_PREPARE + EXECUTE + CLOSE) | `mysql_stmt_prepare` + execute + close per call |
| cached / prepared | default cache | `MYSQL_STMT` reused (`mysql_stmt_execute` only) |

Every repetition runs all drivers in turn (interleaved). Output is two tables (unprepared,
cached) of ops/s (rows/s for `fetch_100k`), median of 7, with `zx.Db vs libmysql` ratios, plus a
table of client CPU per op (process CPU time, so it isn't hidden by network latency).

To profile one driver, `--profile <zx|libmysql> <workload> <url>` loops a cached-mode workload
for ~10s; attach `sample <pid>` (macOS) or `perf` (Linux), or wrap it in `/usr/bin/time -l`.

## Run

```sh
docker run -d --rm --name mysql-bench -e MYSQL_ROOT_PASSWORD=pw -e MYSQL_DATABASE=test -p 3306:3306 mysql:8.4

# libmysqlclient is optional; without -Dmysql its rows are skipped
zig build run -Dmysql=$(brew --prefix mysql-client) -- \
  'mysql://root:pw@127.0.0.1:3306/test?sslmode=disable'
```

### Over TLS

Add `sslmode=require` to the URL. zx.Db uses `std.crypto.tls` (MySQL servers that send a TLS
`CertificateRequest` are not supported yet — use `prefer`, which falls back to plaintext, or
`disable`). libmysqlclient uses its own OpenSSL.

Builds default to `-Doptimize=fast`. On macOS, Docker's VM network adds about 100 µs per round
trip, which hides client cost. For client-bound numbers, build for Linux and run inside the server
container over loopback:

```sh
zig build -Dtarget=aarch64-linux-musl --prefix /tmp/mysql-bench-linux   # or x86_64-linux-musl
docker cp /tmp/mysql-bench-linux/bin/mysql-bench mysql-bench:/tmp/mysql-bench
docker exec mysql-bench /tmp/mysql-bench 'mysql://root:pw@127.0.0.1:3306/test?sslmode=disable'
```
