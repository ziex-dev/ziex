/**
 * Cloudflare D1 implements the generic {@link Database} binding.
 * Prefer the generic names; D1* aliases are for Workers-typed `env.DB`.
 */
export { createDbHandlers } from "../../runtime/db";
export type {
    Database,
    Database as D1Database,
    PreparedStatement,
    PreparedStatement as D1PreparedStatement,
    ExecResult,
    ExecResult as D1ExecResult,
    DbValue,
    DbValue as D1Value,
} from "../../runtime/db";
