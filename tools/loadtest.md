# loadtest.py

Open-loop load generator for the GraphQL API. Stdlib only, no install step.

It is realistic in three ways:

- **The corpus comes from the target.** At startup it reads real names, namehashes,
  owners, resolvers, text keys, coin types, event types and parents-with-subdomains
  out of the endpoint you point it at, and builds every query from those. Local,
  staging and mainnet all work without editing fixtures.
- **The mix is what a name service actually serves** — name page, records panel,
  profile, search, subdomains, history, feeds, crawler pages — weighted so cheap
  lookups dominate and heavy list pages are rare.
- **Arrivals are open-loop** (Poisson at a target rate) and latency is measured from
  the *intended* send time, so a server that falls behind shows queueing instead of
  the generator quietly slowing down with it (coordinated omission).

Every shape runs once before the load starts; the run aborts if any of them returns
a GraphQL error, so "valid queries" is checked rather than assumed.

## Usage

```bash
# check the mix without generating load
tools/loadtest.py --url http://127.0.0.1:8080/graphql --validate-only
tools/loadtest.py --url ... --list-shapes

# steady state
tools/loadtest.py --url http://127.0.0.1:8080/graphql --rps 25 --duration 120

# ramp to find the knee
tools/loadtest.py --url ... --rps 5,10,20,40,80 --stage-duration 30

# isolate one shape
tools/loadtest.py --url ... --shape name_search --rps 40 --csv search.csv
```

## Reading the output

| column | meaning |
|---|---|
| `svc` | service time: send → last byte. **This is the API's latency.** |
| `queue` | how long a request waited past its scheduled send time. |
| `total` | `queue + svc`, measured from the intended send time. |

**Trust `svc` first, and only trust `total` while `queue` is near zero.** A large
`queue` means the generator could not keep up, and then `total` describes the harness
rather than the API. The ramp table prints `queue p50` per stage and warns explicitly
when a stage was generator-bound.

Sizing rule: `N` workers each hold one request for `svc` seconds, so the harness tops
out near `concurrency / svc`. At 1.3 s service time, 64 workers cap out around 48 rps.
If you are testing a slow endpoint, raise `--concurrency` well above
`target_rps × svc_seconds` or the ramp measures the wrong thing.

Outcomes are split into `ok` / `rate_limited` (429) / `client_error` / `server_error` /
`graphql_error` (HTTP 200 with an `errors` field) / `redirect` / `transport`. Only `ok`
responses are counted as served; 429s do not pollute the latency stats.

## Query shapes

`--list-shapes` prints the live weighting. Current mix:

| shape | weight | models |
|---|---|---|
| `name_page` | 20% | opening a name (the app's field set) |
| `name_records` | 15% | records panel: `addr`, `text(key:)`, `texts`, `coinTypes`, `contentHash` |
| `profile_page` | 10% | account page: names + registrations |
| `meta_poll` | 8% | head-block polling (indexers, uptime, app header) |
| `name_search` | 8% | search-as-you-type (`name_contains`) |
| `subdomains` | 7% | subdomain listing under a parent |
| `name_history` | 7% | activity timeline for one name |
| `name_by_namehash` | 6% | marketplace / wallet addressing |
| `recent_registrations` | 6% | "recently registered" feed |
| `domains_page` | 5% | crawler page walk |
| `owner_names` | 4% | names owned by an address |
| `connection_page` | 3% | cursor pagination + `totalCount` |
| `expiring_soon` | 3% | expiry dashboard |
| `events_feed` | 3% | activity feed filtered by event type |
| `multi_name` | 3% | 5 aliased `domain()` lookups in one request |
| `resolver_page` | 2% | resolver inspection (portal / admin) |

## Gotchas

- **Rate limiting.** The per-IP token bucket (`RATE_LIMIT_PER_SECOND`, burst 2×) will
  cap a single-host run. Either stay under it, raise it for the test window, or read
  the `rate_limited` count in the outcome line and treat it as the real ceiling.
- **Cloudflare blocks the default Python user agent** in front of staging, which is
  why the script sends a curl-compatible one. Override with `--user-agent`.
- **`--warmup` (default 5 s) is excluded** from the stats: the first requests pay cold
  caches and pool warm-up.
- **Use a fixed `--seed`** (default 1234) when comparing two runs — the query stream is
  then identical across them.
- `--csv` writes every sample (`shape,total_ms,service_ms,status,kind,bytes,t_done,queue_ms,stage`)
  for offline analysis.
- The generator is one process. Past a few hundred rps, run several instances from
  different hosts rather than raising `--concurrency` indefinitely.

## What it does not cover

Mutations, webhooks and the admin surface; per-request auth headers beyond
`--header`; and any shape that needs data the corpus seeder could not find (those are
flagged as `(empty result)` during validation).
