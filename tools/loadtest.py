#!/usr/bin/env python3
"""Open-loop load test for the ENSv2 GraphQL API.

Realistic in three ways:

  * The corpus is seeded from the target itself at startup — names, namehashes,
    owners, resolvers, text keys and contract addresses are read out of the live
    dataset, so every generated query matches data that exists. Point it at
    local, staging or mainnet and it adapts.
  * The query mix is the shapes a name service actually serves (name page,
    records, profile, search, subdomains, history, feeds, crawler pages),
    weighted so cheap lookups dominate and heavy list pages are rare.
  * Arrivals are open-loop (Poisson at a target rate) and latency is measured
    from the INTENDED send time, so a server that falls behind shows queueing
    delay instead of silently throttling the generator (coordinated omission).

Every shape is executed once before the run starts; the run aborts if any of
them returns a GraphQL error, so "valid queries" is enforced, not assumed.

    tools/loadtest.py --url http://127.0.0.1:8080/graphql --rps 25 --duration 60
    tools/loadtest.py --url https://staging-graphql.ens.dev/graphql --rps 8 --duration 120
    tools/loadtest.py --url ... --validate-only          # check the mix, run nothing
    tools/loadtest.py --url ... --shape name_page --rps 50
    tools/loadtest.py --url ... --rps 5,10,20,40 --stage-duration 30   # ramp

Stdlib only. Latency samples exclude the warm-up window.
"""

from __future__ import annotations

import argparse
import json
import queue
import random
import ssl
import statistics
import sys
import threading
import time
import urllib.parse
from collections import defaultdict
from http.client import HTTPConnection, HTTPSConnection

DEFAULT_UA = "ens-loadtest/1.0 (+curl-compatible)"


# ---------------------------------------------------------------------------
# transport: one keep-alive connection per worker, reconnecting when the server
# closes it (the API answers HTTP/1.1 and may close after a response).
# ---------------------------------------------------------------------------


class Client:
    def __init__(self, url: str, headers: dict[str, str], timeout: float):
        parts = urllib.parse.urlsplit(url)
        self.https = parts.scheme == "https"
        self.host = parts.hostname
        self.port = parts.port or (443 if self.https else 80)
        self.path = parts.path or "/graphql"
        self.headers = headers
        self.timeout = timeout
        self.conn = None

    def _connect(self):
        if self.https:
            ctx = ssl.create_default_context()
            self.conn = HTTPSConnection(self.host, self.port, timeout=self.timeout, context=ctx)
        else:
            self.conn = HTTPConnection(self.host, self.port, timeout=self.timeout)

    def post(self, body: bytes) -> tuple[int, bytes]:
        """Returns (status, body). Retries once on a closed keep-alive socket."""
        for attempt in (0, 1):
            if self.conn is None:
                self._connect()
            try:
                self.conn.request("POST", self.path, body=body, headers=self.headers)
                resp = self.conn.getresponse()
                data = resp.read()
                if resp.will_close:
                    self.close()
                return resp.status, data
            except Exception:
                self.close()
                if attempt == 1:
                    raise
        raise AssertionError("unreachable")

    def close(self):
        if self.conn is not None:
            try:
                self.conn.close()
            except Exception:
                pass
            self.conn = None


def post_once(url: str, headers: dict[str, str], timeout: float, query: str, variables=None):
    c = Client(url, headers, timeout)
    try:
        payload = {"query": query}
        if variables:
            payload["variables"] = variables
        status, body = c.post(json.dumps(payload).encode())
        return status, body
    finally:
        c.close()


# ---------------------------------------------------------------------------
# corpus: read real values out of the target so the generated queries resolve
# ---------------------------------------------------------------------------


SEED_QUERIES = {
    "recent": """{ domains(first: 200, orderBy: createdAt, orderDirection: desc) {
        name id owner { id } resolver { address } expiryDate } }""",
    "by_name": """{ domains(first: 200, orderBy: name, orderDirection: asc) {
        name id owner { id } } }""",
    "parents": '{ domains(first: 50, where: { hasSubdomains: true }) { name id subdomainCount } }',
    "registrations": "{ registrations(first: 100, orderBy: registrationDate, orderDirection: desc) { name registrant { id } } }",
    "accounts": "{ accounts(first: 100) { id } }",
    "resolvers": "{ resolvers(first: 50) { address texts coinTypes } }",
    "events": "{ events(first: 100) { type contractAddress blockNumber } }",
    "meta": "{ _meta { block { number } } }",
}


class Corpus:
    def __init__(self):
        self.names: list[str] = []
        self.namehashes: list[str] = []
        self.owners: list[str] = []
        self.resolvers: list[str] = []
        self.parents: list[str] = []
        self.registrants: list[str] = []
        self.accounts: list[str] = []
        self.reg_names: list[str] = []
        self.text_keys: list[str] = []
        self.coin_types: list[str] = []
        self.event_types: list[str] = []
        self.contracts: list[str] = []
        self.search_terms: list[str] = []
        self.expiries: list[int] = []
        self.head_block: int = 0

    def ok(self) -> bool:
        return bool(self.names and self.namehashes)

    def summary(self) -> str:
        return (
            f"names={len(self.names)} namehashes={len(self.namehashes)} owners={len(self.owners)} "
            f"resolvers={len(self.resolvers)} parents={len(self.parents)} accounts={len(self.accounts)} "
            f"registrations={len(self.reg_names)} textKeys={len(self.text_keys)} "
            f"coinTypes={len(self.coin_types)} eventTypes={len(self.event_types)} head={self.head_block}"
        )


def dedupe(seq):
    seen, out = set(), []
    for x in seq:
        if x is None or x in seen:
            continue
        seen.add(x)
        out.append(x)
    return out


def seed_corpus(url, headers, timeout, verbose=True) -> Corpus:
    c = Corpus()
    raw = {}
    for key, q in SEED_QUERIES.items():
        try:
            status, body = post_once(url, headers, timeout, q)
            doc = json.loads(body)
            if status != 200 or "errors" in doc:
                if verbose:
                    msg = doc.get("errors", [{}])[0].get("message", body[:120]) if isinstance(doc, dict) else body[:120]
                    print(f"  seed {key}: HTTP {status} {msg}", file=sys.stderr)
                continue
            raw[key] = doc.get("data") or {}
        except Exception as e:  # noqa: BLE001 - a missing seed degrades the mix, not the run
            if verbose:
                print(f"  seed {key}: {e}", file=sys.stderr)

    for row in (raw.get("recent", {}).get("domains") or []) + (raw.get("by_name", {}).get("domains") or []):
        if row.get("name"):
            c.names.append(row["name"])
        if row.get("id"):
            c.namehashes.append(row["id"])
        if (row.get("owner") or {}).get("id"):
            c.owners.append(row["owner"]["id"])
        if (row.get("resolver") or {}).get("address"):
            c.resolvers.append(row["resolver"]["address"])
        if isinstance(row.get("expiryDate"), int) and row["expiryDate"] > 0:
            c.expiries.append(row["expiryDate"])

    for row in raw.get("parents", {}).get("domains") or []:
        if row.get("name"):
            c.parents.append(row["name"])

    for row in raw.get("registrations", {}).get("registrations") or []:
        if row.get("name"):
            c.reg_names.append(row["name"])
        if (row.get("registrant") or {}).get("id"):
            c.registrants.append(row["registrant"]["id"])

    for row in raw.get("accounts", {}).get("accounts") or []:
        if row.get("id"):
            c.accounts.append(row["id"])

    for row in raw.get("resolvers", {}).get("resolvers") or []:
        if row.get("address"):
            c.resolvers.append(row["address"])
        for k in row.get("texts") or []:
            c.text_keys.append(k)
        for ct in row.get("coinTypes") or []:
            c.coin_types.append(str(ct))

    for row in raw.get("events", {}).get("events") or []:
        if row.get("type"):
            c.event_types.append(row["type"])
        if row.get("contractAddress"):
            c.contracts.append(row["contractAddress"])

    block = ((raw.get("meta", {}).get("_meta") or {}).get("block") or {}).get("number")
    c.head_block = int(block or 0)

    for f in ("names", "namehashes", "owners", "resolvers", "parents", "registrants",
              "accounts", "reg_names", "text_keys", "coin_types", "event_types", "contracts"):
        setattr(c, f, dedupe(getattr(c, f)))

    # Search terms taken from real labels, so `name_contains` matches something.
    for n in c.names[:200]:
        label = n.split(".")[0]
        if len(label) >= 3 and label.isalnum():
            c.search_terms.append(label[:3])
    c.search_terms = dedupe(c.search_terms) or ["eth", "a", "test"]
    c.accounts = c.accounts or c.owners
    c.text_keys = c.text_keys or ["avatar", "url", "com.twitter", "description"]
    c.coin_types = c.coin_types or ["60"]
    c.event_types = c.event_types or ["Transfer", "NameRegistered"]
    return c


# ---------------------------------------------------------------------------
# query mix — shapes a client actually sends, weighted by how often
# ---------------------------------------------------------------------------


def build_shapes(c: Corpus):
    """Each shape returns (query, variables). Weights are relative."""
    R = random.Random()

    def name():
        return R.choice(c.names)

    def namehash():
        return R.choice(c.namehashes)

    def owner():
        return R.choice(c.owners) if c.owners else R.choice(c.accounts)

    def account():
        return R.choice(c.accounts)

    shapes = []

    def shape(key, weight):
        def register(fn):
            shapes.append({"key": key, "weight": weight, "gen": fn})
            return fn
        return register

    # Indexers, uptime checks and the app's header all poll the head block.
    @shape("meta_poll", 8)
    def _meta(_):
        return "{ _meta { block { number hash } hasIndexingErrors } }", None

    # The name page: the field set the app requests when you open a name.
    @shape("name_page", 20)
    def _name_page(_):
        q = """query($id:String!){ domain(id:$id){
            id name labelName labelhash owner { id } registrant { id } wrappedOwner { id }
            resolver { id address } isWrapped fuses wrapperExpiry isReachable protocol
            subdomainCount expiryDate registrationDate createdAt tokenId } }"""
        return q, {"id": name()}

    # The records panel: avatar/text/address records for one name.
    @shape("name_records", 15)
    def _records(_):
        q = """query($id:String!,$key:String!,$ct:Int!){ domain(id:$id){
            name resolvedAddress { id }
            resolver { id address addr addr2: addr(coinType:$ct) contentHash texts coinTypes
                       avatar: text(key:$key) } } }"""
        return q, {"id": name(), "key": R.choice(c.text_keys), "ct": int(R.choice(c.coin_types))}

    # Marketplaces and wallets address names by namehash / tokenId.
    @shape("name_by_namehash", 6)
    def _by_hash(_):
        q = """query($id:String!){ domain(id:$id){
            id name owner { id } resolver { address } expiryDate isWrapped tokenId } }"""
        return q, {"id": namehash()}

    # Profile page: an account's names and registrations in one round trip.
    @shape("profile_page", 10)
    def _profile(_):
        q = """query($id:String!){ account(id:$id){
            id primaryName seenV1 seenV2
            domains(first:10){ name expiryDate resolver { address } }
            registrations(first:10){ expiryDate domain { name } } } }"""
        return q, {"id": account()}

    # Search-as-you-type.
    @shape("name_search", 8)
    def _search(_):
        q = """query($term:String!){ domains(first:10, where:{ name_contains:$term },
            orderBy:name, orderDirection:asc){ id name owner { id } expiryDate } }"""
        return q, {"term": R.choice(c.search_terms)}

    # Subdomain listing under a parent that has children.
    @shape("subdomains", 7)
    def _subdomains(_):
        parent = R.choice(c.parents) if c.parents else name()
        q = """query($id:String!){ domain(id:$id){
            name subdomainCount
            subdomains(first:20){ id name owner { id } expiryDate resolver { address } } } }"""
        return q, {"id": parent}

    # Name history timeline.
    @shape("name_history", 7)
    def _history(_):
        q = """query($id:String!){ domain(id:$id){
            name eventsCount
            events(first:20, orderBy:blockNumber, orderDirection:desc){
                id type blockNumber timestamp transactionHash } } }"""
        return q, {"id": name()}

    # "Recently registered" feed.
    @shape("recent_registrations", 6)
    def _recent(_):
        q = """{ registrations(first:20, orderBy:registrationDate, orderDirection:desc){
            id registrationDate expiryDate registrant { id } domain { name owner { id } } } }"""
        return q, None

    # Crawler / indexer page walk.
    @shape("domains_page", 5)
    def _page(_):
        skip = R.choice([0, 100, 500, 1000])
        q = """query($skip:Int!){ domains(first:50, skip:$skip, orderBy:createdAt, orderDirection:desc){
            id name owner { id } resolver { address } expiryDate isWrapped protocol } }"""
        return q, {"skip": skip}

    # Cursor pagination (the connection API).
    @shape("connection_page", 3)
    def _conn(_):
        q = """{ domainConnection(first:25, orderBy:createdAt, orderDirection:desc){
            totalCount pageInfo { hasNextPage endCursor }
            edges { cursor node { id name owner { id } } } } }"""
        return q, None

    # Expiry dashboards.
    @shape("expiring_soon", 3)
    def _expiring(_):
        now = int(time.time())
        q = """query($lo:Int!,$hi:Int!){ domains(first:25, where:{ expiryDate_gt:$lo, expiryDate_lt:$hi },
            orderBy:expiryDate, orderDirection:asc){ id name expiryDate registrant { id } } }"""
        return q, {"lo": now, "hi": now + 90 * 24 * 3600}

    # "Names owned by this address".
    @shape("owner_names", 4)
    def _owned(_):
        q = """query($owner:String!){ domains(first:25, where:{ owner:$owner },
            orderBy:createdAt, orderDirection:desc){ id name expiryDate resolver { address } } }"""
        return q, {"owner": owner()}

    # Activity feed filtered by event type.
    @shape("events_feed", 3)
    def _events(_):
        types = R.sample(c.event_types, min(2, len(c.event_types)))
        q = """query($types:[String!]){ events(first:25, where:{ type_in:$types },
            orderBy:blockNumber, orderDirection:desc){
            id type blockNumber timestamp domain { name } } }"""
        return q, {"types": types}

    # Resolver inspection (portal / admin).
    @shape("resolver_page", 2)
    def _resolver(_):
        q = """query($addr:String!){ resolvers(first:10, where:{ address_in:[$addr] }){
            id address texts coinTypes domain { name owner { id } } } }"""
        return q, {"addr": R.choice(c.resolvers)} if c.resolvers else ("{ resolvers(first:10){ id address } }", None)

    # Batched multi-name lookup (wallets resolving a page of names at once).
    @shape("multi_name", 3)
    def _multi(_):
        picks = R.sample(c.names, min(5, len(c.names)))
        parts = []
        for i, n in enumerate(picks):
            parts.append(f'd{i}: domain(id: "{n}") {{ name owner {{ id }} resolver {{ address }} expiryDate }}')
        return "{ " + " ".join(parts) + " }", None

    return shapes


# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.samples = []            # (shape, total_ms, service_ms, status, kind, bytes, t_done)
        self.counts = defaultdict(int)

    def add(self, *row):
        with self.lock:
            self.samples.append(row)
            self.counts[row[4]] += 1

    def snapshot(self):
        with self.lock:
            return list(self.samples), dict(self.counts)


# A graphql_error is an HTTP 200 whose body carries an "errors" field, so the
# reason is IN that body — and until now classify() read it and threw it away.
# A run could report "20% of profile_page failed" with no way to say why, which
# is the one thing the operator needs. Keep the first few distinct messages per
# shape (bounded, so a failing shape cannot grow this without limit) and print
# them in the summary.
GQL_ERRORS = {}
GQL_ERRORS_LOCK = threading.Lock()
MAX_MSGS_PER_SHAPE = 3


def record_gql_error(shape, body):
    try:
        errs = json.loads(body).get("errors") or []
        msgs = [str(e.get("message", e))[:200] for e in errs] or ["<errors field present but empty>"]
    except Exception:
        # A body that is not JSON is itself the finding; keep a prefix verbatim.
        msgs = ["<unparseable body> " + body[:160].decode("utf-8", "replace")]
    with GQL_ERRORS_LOCK:
        seen = GQL_ERRORS.setdefault(shape, {})
        for m in msgs:
            if m in seen:
                seen[m] += 1
            elif len(seen) < MAX_MSGS_PER_SHAPE:
                seen[m] = 1


def classify(status, body):
    if status == 0:
        return "transport"
    if status == 429:
        return "rate_limited"
    if status >= 500:
        return "server_error"
    if status >= 400:
        return "client_error"
    if status >= 300:
        # A redirect (http -> https, say) is not a served query: counting it as
        # ok would report a fast, empty run as a healthy one.
        return "redirect"
    if b'"errors"' in body:
        return "graphql_error"
    return "ok"


def stage_rates_of(args):
    return [float(x) for x in args.rps.split(",") if x.strip()]


def pct(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    k = (len(sorted_vals) - 1) * (p / 100.0)
    lo, hi = int(k), min(int(k) + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)


def worker(job_q, client_factory, stats, stop, args):
    client = client_factory()
    try:
        while not stop.is_set():
            try:
                job = job_q.get(timeout=0.25)
            except queue.Empty:
                continue
            if job is None:
                return
            intended, stage, shape_key, query, variables = job
            now = time.perf_counter()
            if intended > now:
                # The scheduler never enqueues more than LOOKAHEAD ahead, so this
                # sleep is short. Capping it would fire the request EARLY and
                # produce negative latency.
                time.sleep(intended - now)
            payload = {"query": query}
            if variables:
                payload["variables"] = variables
            body = json.dumps(payload).encode()
            t0 = time.perf_counter()
            try:
                status, resp = client.post(body)
            except Exception:
                status, resp = 0, b""
                client.close()
            t1 = time.perf_counter()
            kind = classify(status, resp)
            if kind == "graphql_error":
                record_gql_error(shape_key, resp)
            # total = queue delay + service, measured from the INTENDED send time.
            # queue delay is how long the job waited past its schedule: when it is
            # large the GENERATOR is behind, not the server.
            stats.add(shape_key, (t1 - intended) * 1000.0, (t1 - t0) * 1000.0,
                      status, kind, len(resp), t1, (t0 - intended) * 1000.0, stage)
    finally:
        client.close()


# Never enqueue a job more than this far ahead of its send time. Bounding the
# horizon in TIME (not in queue depth) keeps the offered rate equal to the
# configured rate: a depth bound lets the scheduler race minutes ahead at low
# rates, and the queue then drains at worker speed instead of at the target rate.
LOOKAHEAD_S = 0.25


def run_stage(stage_idx, rps, duration, shapes, weights, job_q, stats, args, stop):
    """Schedule Poisson arrivals at `rps` for `duration` seconds."""
    rnd = random.Random(args.seed + stage_idx * 7919 + int(rps * 1000))
    t = time.perf_counter() + 0.05
    deadline = t + duration
    scheduled = 0
    while t < deadline and not stop.is_set():
        now = time.perf_counter()
        if t - now > LOOKAHEAD_S:
            time.sleep(min(t - now - LOOKAHEAD_S, 0.05))
            continue
        shape = rnd.choices(shapes, weights=weights, k=1)[0]
        query, variables = shape["gen"](rnd)
        job_q.put((t, stage_idx, shape["key"], query, variables))
        gap = rnd.expovariate(rps) if args.arrival == "poisson" else 1.0 / rps
        t += gap
        scheduled += 1
    # let the stage's own tail land before the next rate starts
    while not job_q.empty() and not stop.is_set():
        time.sleep(0.02)
    return scheduled


def stage_table(kept, stage_rates, stage_dur, args):
    """Per-stage summary — the point of a ramp. `queue` is the delay past the
    intended send time: when it grows, the GENERATOR is the bottleneck, not the
    server, and the total column stops meaning anything about the service."""
    print()
    print(f"{'stage':<14} {'target':>7} {'actual':>7} {'n':>6} {'svc p50':>8} {'svc p95':>8} "
          f"{'svc p99':>8} {'queue p50':>10} {'tot p99':>9} {'err':>5}")
    saturated = []
    for i, rate in enumerate(stage_rates):
        rows = [s for s in kept if s[8] == i]
        if not rows:
            print(f"{i}: {rate:g}/s{'':<6} {rate:>7.0f} {'—':>7} {0:>6}")
            continue
        svc = sorted(r[2] for r in rows)
        tot = sorted(r[1] for r in rows)
        q = sorted(r[7] for r in rows)
        span = max(r[6] for r in rows) - min(r[6] for r in rows)
        actual = len(rows) / max(1e-9, span)
        bad = sum(1 for r in rows if r[4] != "ok")
        print(f"{i}: {rate:g}/s{'':<6} {rate:>7.0f} {actual:>7.1f} {len(rows):>6} "
              f"{pct(svc,50):>8.0f} {pct(svc,95):>8.0f} {pct(svc,99):>8.0f} "
              f"{pct(q,50):>10.0f} {pct(tot,99):>9.0f} {bad:>5}")
        # N workers each holding a request for svc seconds sustain N/svc req/s.
        # Which side is the bottleneck is decided by the QUEUE column, not by the
        # rate shortfall: a shortfall with an empty queue means the SERVER could
        # not absorb the offered rate.
        ceiling = args.concurrency / max(1e-6, pct(svc, 50) / 1000.0)
        if pct(q, 50) > 250:
            saturated.append(("generator", rate, actual, ceiling))
        elif actual < rate * 0.9:
            saturated.append(("server", rate, actual, ceiling))
    if saturated:
        print()
        for kind, rate, actual, ceiling in saturated:
            if kind == "generator":
                print(f"  ! generator-bound: target {rate:g}/s -> {actual:.1f}/s, queue delay high. "
                      f"{args.concurrency} workers cap the harness near {ceiling:.0f}/s; "
                      f"re-run with --concurrency {max(args.concurrency * 2, int(ceiling * 2)):d}. "
                      f"Its total/p99 columns measure the harness, not the API.")
            else:
                print(f"  ! SERVER-bound: target {rate:g}/s -> {actual:.1f}/s achieved with an empty "
                      f"queue (harness headroom ~{ceiling:.0f}/s). The API could not absorb the "
                      f"offered rate — this is the saturation point.")


def report(samples, counts, args, stages, wall):
    warm_cut = min(s[6] for s in samples) if samples else 0
    kept = [s for s in samples if s[6] >= warm_cut]
    if args.warmup > 0 and samples:
        t0 = min(s[6] for s in samples)
        kept = [s for s in samples if s[6] - t0 >= args.warmup]

    ok = [s for s in kept if s[4] == "ok"]
    print()
    print("=" * 78)
    print(f"target     {args.url}")
    print(f"stages     {stages}  arrival={args.arrival}  workers={args.concurrency}  seed={args.seed}")
    print(f"wall       {wall:.1f}s   warmup excluded: {args.warmup:.0f}s")
    print(f"requests   {len(samples)} sent, {len(kept)} measured, {len(ok)} ok "
          f"({100.0 * len(ok) / max(1, len(kept)):.1f}%)")
    achieved = len(kept) / max(1e-9, (wall - args.warmup))
    print(f"throughput {achieved:.1f} req/s achieved")
    if counts:
        parts = [f"{k}={v}" for k, v in sorted(counts.items(), key=lambda kv: -kv[1])]
        print("outcomes   " + "  ".join(parts))
    print("-" * 78)

    def line(label, rows):
        if not rows:
            return
        tot = sorted(r[1] for r in rows)
        svc = sorted(r[2] for r in rows)
        bad = sum(1 for r in rows if r[4] != "ok")
        size = statistics.mean(r[5] for r in rows) / 1024.0
        print(f"{label:<22} {len(rows):>6} {pct(tot,50):>8.0f} {pct(tot,90):>8.0f} "
              f"{pct(tot,95):>8.0f} {pct(tot,99):>8.0f} {tot[-1]:>9.0f} {pct(svc,50):>8.0f} "
              f"{size:>8.1f} {bad:>5}")

    if len(stage_rates_of(args)) > 1:
        stage_table(kept, stage_rates_of(args), args.stage_duration, args)
        print("-" * 78)

    print(f"{'shape':<22} {'n':>6} {'p50':>8} {'p90':>8} {'p95':>8} {'p99':>8} "
          f"{'max':>9} {'svc p50':>8} {'KiB':>8} {'err':>5}")
    by_shape = defaultdict(list)
    for s in kept:
        by_shape[s[0]].append(s)
    for key in sorted(by_shape, key=lambda k: -pct(sorted(x[1] for x in by_shape[k]), 99)):
        line(key, by_shape[key])
    print("-" * 78)
    line("ALL", kept)
    line("ALL (ok only)", ok)

    if kept:
        tot = sorted(s[1] for s in kept)
        print()
        print(f"p99.9 {pct(tot, 99.9):.0f} ms    slowest 5: "
              + ", ".join(f"{s[0]} {s[1]:.0f}ms" for s in sorted(kept, key=lambda s: -s[1])[:5]))

    if GQL_ERRORS:
        print("\n" + "-" * 78)
        print("graphql errors (HTTP 200 with an errors field) — distinct messages per shape:")
        for shape in sorted(GQL_ERRORS, key=lambda k: -sum(GQL_ERRORS[k].values())):
            for msg, count in sorted(GQL_ERRORS[shape].items(), key=lambda kv: -kv[1]):
                print(f"  {shape:<22} x{count:<5} {msg}")

    if args.csv:
        with open(args.csv, "w") as fh:
            fh.write("shape,total_ms,service_ms,status,kind,bytes,t_done,queue_ms,stage\n")
            for s in samples:
                fh.write(f"{s[0]},{s[1]:.3f},{s[2]:.3f},{s[3]},{s[4]},{s[5]},{s[6]:.6f},"
                         f"{s[7]:.3f},{s[8]}\n")
        print(f"\nraw samples -> {args.csv}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True, help="GraphQL endpoint, e.g. http://127.0.0.1:8080/graphql")
    ap.add_argument("--rps", default="10", help="target rate; comma-separated for a ramp (e.g. 5,10,20,40)")
    ap.add_argument("--duration", type=float, default=60.0, help="seconds (single stage)")
    ap.add_argument("--stage-duration", type=float, default=None, help="seconds per stage when --rps is a list")
    ap.add_argument("--concurrency", type=int, default=64, help="worker threads (in-flight ceiling)")
    ap.add_argument("--warmup", type=float, default=5.0, help="seconds excluded from the stats")
    ap.add_argument("--timeout", type=float, default=60.0, help="per-request socket timeout (s)")
    ap.add_argument("--arrival", choices=["poisson", "uniform"], default="poisson")
    ap.add_argument("--shape", action="append", help="restrict the mix to these shapes (repeatable)")
    ap.add_argument("--list-shapes", action="store_true", help="print the shape mix and exit")
    ap.add_argument("--validate-only", action="store_true", help="run each shape once, report, exit")
    ap.add_argument("--allow-invalid", action="store_true", help="do not abort when a shape fails validation")
    ap.add_argument("--header", action="append", default=[], help="extra header 'K: V' (repeatable)")
    ap.add_argument("--user-agent", default=DEFAULT_UA)
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--csv", help="write raw samples to this file")
    args = ap.parse_args()

    headers = {
        "content-type": "application/json",
        "accept": "application/json",
        "user-agent": args.user_agent,
        "accept-encoding": "identity",
    }
    for h in args.header:
        k, _, v = h.partition(":")
        headers[k.strip()] = v.strip()

    print(f"seeding corpus from {args.url} ...", file=sys.stderr)
    corpus = seed_corpus(args.url, headers, args.timeout)
    if not corpus.ok():
        print("FATAL: could not read any names from the target — is it reachable and indexed?", file=sys.stderr)
        return 2
    print(f"corpus: {corpus.summary()}", file=sys.stderr)

    shapes = build_shapes(corpus)
    if args.shape:
        wanted = set(args.shape)
        unknown = wanted - {s["key"] for s in shapes}
        if unknown:
            print(f"unknown shape(s): {', '.join(sorted(unknown))}", file=sys.stderr)
            return 2
        shapes = [s for s in shapes if s["key"] in wanted]

    if args.list_shapes:
        total = sum(s["weight"] for s in shapes)
        for s in shapes:
            print(f"{s['key']:<22} {100.0 * s['weight'] / total:5.1f}%")
        return 0

    # Validation pass: every shape must execute cleanly against the target.
    print("validating shapes ...", file=sys.stderr)
    rnd = random.Random(args.seed)
    failed = []
    for s in shapes:
        query, variables = s["gen"](rnd)
        try:
            status, body = post_once(args.url, headers, args.timeout, query, variables)
            kind = classify(status, body)
        except Exception as e:  # noqa: BLE001
            status, body, kind = 0, str(e).encode(), "transport"
        if kind == "ok":
            try:
                doc = json.loads(body)
            except ValueError:
                doc = {}
            empty = not any(doc.get("data", {}).values()) if isinstance(doc.get("data"), dict) else True
            note = "  (empty result — corpus may not cover this shape)" if empty else ""
            print(f"  ok   {s['key']:<22} {len(body):>8} B{note}", file=sys.stderr)
        else:
            msg = body[:200].decode("utf-8", "replace")
            print(f"  FAIL {s['key']:<22} [{kind} {status}] {msg}", file=sys.stderr)
            failed.append(s["key"])
    if failed and not args.allow_invalid:
        print(f"\n{len(failed)} shape(s) invalid: {', '.join(failed)}. "
              f"Fix them (or pass --allow-invalid) before load-testing.", file=sys.stderr)
        return 1
    if args.validate_only:
        return 0

    stage_rates = stage_rates_of(args)
    stage_dur = args.stage_duration or (args.duration / len(stage_rates) if len(stage_rates) > 1 else args.duration)
    args.stage_duration = stage_dur

    weights = [s["weight"] for s in shapes]
    job_q: queue.Queue = queue.Queue()
    stats = Stats()
    stop = threading.Event()

    def client_factory():
        return Client(args.url, headers, args.timeout)

    workers = [threading.Thread(target=worker, args=(job_q, client_factory, stats, stop, args), daemon=True)
               for _ in range(args.concurrency)]
    for w in workers:
        w.start()

    stages_desc = " -> ".join(f"{r:g}/s x {stage_dur:g}s" for r in stage_rates)
    print(f"\nrunning: {stages_desc}   (ctrl-c to stop early)\n", file=sys.stderr)

    t_wall = time.perf_counter()
    progress_stop = threading.Event()

    def progress():
        last = 0
        while not progress_stop.wait(5.0):
            samples, counts = stats.snapshot()
            n = len(samples)
            recent = [s for s in samples[last:]]
            last = n
            if recent:
                svc = sorted(s[2] for s in recent)
                q = sorted(s[7] for s in recent)
                bad = sum(1 for s in recent if s[4] != "ok")
                flag = "  <- generator behind" if pct(q, 50) > 250 else ""
                print(f"  t={time.perf_counter() - t_wall:6.0f}s  n={n:<7} "
                      f"last5s: {len(recent)/5:.1f}/s svc p50={pct(svc,50):.0f}ms "
                      f"svc p99={pct(svc,99):.0f}ms queue p50={pct(q,50):.0f}ms err={bad}{flag}",
                      file=sys.stderr)

    pt = threading.Thread(target=progress, daemon=True)
    pt.start()

    try:
        for i, rate in enumerate(stage_rates):
            run_stage(i, rate, stage_dur, shapes, weights, job_q, stats, args, stop)
        # let the tail drain
        while not job_q.empty():
            time.sleep(0.1)
        time.sleep(1.0)
    except KeyboardInterrupt:
        print("\ninterrupted — draining", file=sys.stderr)
    finally:
        progress_stop.set()
        stop.set()
        for _ in workers:
            job_q.put(None)
        for w in workers:
            w.join(timeout=2.0)

    wall = time.perf_counter() - t_wall
    samples, counts = stats.snapshot()
    report(samples, counts, args, stages_desc, wall)
    return 0


if __name__ == "__main__":
    sys.exit(main())
