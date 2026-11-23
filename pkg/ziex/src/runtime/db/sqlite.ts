/**
 * Native SQLite client binding - not implemented yet.
 * Server builds currently use the WASM `db_*` host ops via {@link createDbHandlers}.
 */
export const Sqlite = {
    open(_path: string): never {
        throw new Error("db/sqlite: not implemented yet");
    },
};
