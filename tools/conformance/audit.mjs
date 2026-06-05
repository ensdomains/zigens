// Surface #2: GraphQL-over-HTTP transport conformance, via the official graphql-http
// audit suite. Point it at a running /graphql endpoint.
// Usage: node audit.mjs [http://localhost:8080/graphql]
//
// Locally you need nothing but `npm i` (graphql-http). Node's global fetch is used
// directly. Behind a proxy (HTTPS_PROXY set, e.g. a corporate egress proxy), install
// `undici@6` too and it will route through the proxy automatically.
import { auditServer } from 'graphql-http';

const url = process.argv[2] || 'http://localhost:8080/graphql';
const ua = 'graphql-http-conformance';

let fetchFn = (u, opts = {}) =>
  fetch(u, { ...opts, headers: { 'user-agent': ua, ...(opts.headers || {}) } });

const proxy = process.env.HTTPS_PROXY || process.env.https_proxy;
if (proxy && url.startsWith('https')) {
  const { fetch: ufetch, ProxyAgent } = await import('undici'); // optional dep, only behind a proxy
  const dispatcher = new ProxyAgent(proxy);
  fetchFn = (u, opts = {}) =>
    ufetch(u, { ...opts, dispatcher, headers: { 'user-agent': ua, ...(opts.headers || {}) } });
}

const results = await auditServer({ url, fetchFn });

// graphql-http derives status purely from the title prefix (see lib/audits/utils.js):
//   MUST -> 'error', SHOULD -> 'warn', everything else (MAY) -> 'notice'.
// Only 'error' is a real conformance failure; 'warn'/'notice' are recommendations/optionals.
const buckets = { ok: [], warn: [], error: [], notice: [] };
for (const r of results) (buckets[r.status] || (buckets[r.status] = [])).push(r);
const n = (k) => (buckets[k] || []).length;

console.log('GraphQL-over-HTTP audit of ' + url);
console.log(
  '  ' + results.length + ' checks: ok=' + n('ok') +
  '  error(MUST)=' + n('error') + '  warn(SHOULD)=' + n('warn') + '  notice(MAY)=' + n('notice')
);
const show = (label, k) => {
  for (const r of buckets[k] || []) {
    const why = r.reason ? ' -- ' + String(r.reason).split('\n')[0].slice(0, 160) : '';
    console.log('  [' + label + '] ' + r.name + why);
  }
};
show('error/MUST', 'error');
show('warn/SHOULD', 'warn');
if (process.env.SHOW_NOTICE) show('notice/MAY', 'notice');
else if (n('notice')) console.log('  (' + n('notice') + ' optional MAY notices hidden; set SHOW_NOTICE=1 to list)');

process.exit(n('error') ? 1 : 0); // only MUST failures fail the run
