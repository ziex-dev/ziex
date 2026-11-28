export function isRemoteStaticDeploy(): boolean {
  return false;
  const base = process.env.BASE_URL;
  if (!base) return false;
  try {
    const { hostname } = new URL(base);
    return hostname !== 'localhost' && hostname !== '127.0.0.1' && hostname !== '[::1]';
  } catch {
    return false;
  }
}

export const skipOnRemoteStatic = isRemoteStaticDeploy();

/** Standalone `_base` server (`TEMPLATE_TESTS=1`) vs site embed under `/template`. */
export const isTemplateServer = !!process.env.TEMPLATE_TESTS;

/** Root path for the `_base` template app in the current e2e mode. */
export const templateRoot = isTemplateServer ? '/' : '/template';

/** Resolve a template-app path for the current e2e mode. */
export function templateUrl(path = '/'): string {
  if (!path || path === '/') return templateRoot;
  const normalized = path.startsWith('/') ? path : `/${path}`;
  return isTemplateServer ? normalized : `/template${normalized}`;
}

/** Dedicated `bench/ziex` CSR server (`CSR_BENCH=1`) vs site embed under `/bench`. */
export const isCsrBenchServer = !!process.env.CSR_BENCH;

/** Path for the CSR js-framework-benchmark page in the current e2e mode. */
export const csrBenchPath = isCsrBenchServer ? '/' : '/bench';

/** Site served by workerd (`E2E_RUNTIME=edge`) rather than the native dev server. */
export const isEdgeRuntime = process.env.E2E_RUNTIME === 'edge';

/** Postgres/MySQL examples need `POSTGRES_URL`/`MYSQL_URL`; their specs run only with `E2E_EXTERNAL_DB=1`. */
export const withExternalDb = !!process.env.E2E_EXTERNAL_DB;
