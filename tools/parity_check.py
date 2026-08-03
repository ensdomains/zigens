#!/usr/bin/env python3
"""Live subgraph-parity check.

Samples domains from the zigens endpoint (the lagging side, so every sampled
name exists on both), queries zigens and the reference ENS subgraph with the
same document, normalizes, and diffs field-by-field. Known BY-DESIGN
divergences are allowlisted with reasons; anything else fails the run.

Environment:
  PARITY_ZIGENS_URL     zigens /graphql endpoint (required)
  PARITY_SUBGRAPH_URL   ENS subgraph endpoint for the SAME network (required)
  PARITY_SAMPLE         rotating sample size (default 25)
  PARITY_FIXED_NAMES    comma-separated names always checked (optional)
  PARITY_MAX_FAILURES   tolerated unexpected divergences (default 0)
"""
import json
import os
import sys
import urllib.request

try:
    from Crypto.Hash import keccak as _keccak

    def _k(b: bytes) -> bytes:
        h = _keccak.new(digest_bits=256)
        h.update(b)
        return h.digest()

    def namehash(name: str) -> str:
        node = b"\x00" * 32
        if name:
            for label in reversed(name.split(".")):
                node = _k(node + _k(label.encode()))
        return "0x" + node.hex()
except ImportError:  # fixed names then require ids; sampled ids still work
    namehash = None

ZIGENS = os.environ.get("PARITY_ZIGENS_URL", "")
SUBGRAPH = os.environ.get("PARITY_SUBGRAPH_URL", "")
SAMPLE = int(os.environ.get("PARITY_SAMPLE") or "25")
FIXED = [n for n in os.environ.get("PARITY_FIXED_NAMES", "").split(",") if n]
MAX_FAILURES = int(os.environ.get("PARITY_MAX_FAILURES") or "0")

# Fields where a mismatch is expected and CORRECT by design. Each entry
# documents why, so the allowlist can't silently rot into "ignore everything".
ALLOWLIST = {
    # zigens defers name materialization, so labelhash is always known and
    # non-null; the subgraph leaves it null for tokenId-only rows.
    "labelhash:null-vs-value",
    # Upstream subgraph bug: a wrapped name that expired and was re-registered
    # unwrapped keeps stale isWrapped/wrappedOwner in the subgraph (no
    # NameUnwrapped event fires). zigens clears wrap state on re-registration.
    "isWrapped:subgraph-stale-wrap",
}

# zigens exposes isWrapped as a Boolean and resolver.addr as a scalar; the
# subgraph nests them. Query each side in its native shape and normalize below.
ZIGENS_QUERY = """
query($id: String!) {
  domain(id: $id) {
    id
    name
    labelName
    labelhash
    createdAt
    expiryDate
    isWrapped
    protocol
    owner { id }
    registrant { id }
    resolver { addr texts }
  }
}
"""
SUBGRAPH_QUERY = """
query($id: String!) {
  domain(id: $id) {
    id
    name
    labelName
    labelhash
    createdAt
    expiryDate
    wrappedDomain { id }
    owner { id }
    registrant { id }
    resolver { addr { id } texts }
  }
}
"""

# The reference subgraph indexes ENS V1 only, so parity is defined over the V1
# subset. registrations carries the protocol filter (domains does not), and its
# domain link supplies the namehash id both sides resolve.
SAMPLE_QUERY = """
query($n: Int!) {
  registrations(first: $n, orderBy: registrationDate, orderDirection: desc,
                where: { protocol: "v1" }) {
    name
    domain { id }
  }
}
"""


def gql(url: str, query: str, variables: dict) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "zigens-parity/1.0"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.load(r)
    if body.get("errors"):
        raise RuntimeError(f"{url}: {body['errors'][:1]}")
    return body.get("data") or {}


def norm_addr(v):
    return v.lower() if isinstance(v, str) and v.startswith("0x") else v


def normalize(side: str, d: dict | None) -> dict | None:
    if d is None:
        return None
    out = {
        "id": norm_addr(d.get("id")),
        "name": d.get("name"),
        "labelName": d.get("labelName"),
        "labelhash": norm_addr(d.get("labelhash")),
        "createdAt": str(d.get("createdAt")) if d.get("createdAt") is not None else None,
        "expiryDate": str(d.get("expiryDate")) if d.get("expiryDate") is not None else None,
        "owner": norm_addr((d.get("owner") or {}).get("id")),
        "registrant": norm_addr((d.get("registrant") or {}).get("id")),
    }
    if side == "zigens":
        out["isWrapped"] = bool(d.get("isWrapped"))
        res = d.get("resolver")
        out["resolverAddr"] = norm_addr(res.get("addr")) if res else None
        out["texts"] = sorted(res.get("texts") or []) if res else []
    else:
        out["isWrapped"] = d.get("wrappedDomain") is not None
        res = d.get("resolver")
        addr = (res or {}).get("addr")
        out["resolverAddr"] = norm_addr(addr.get("id")) if isinstance(addr, dict) else norm_addr(addr)
        out["texts"] = sorted((res or {}).get("texts") or []) if res else []
    return out


def classify(field: str, zv, sv) -> str | None:
    """Return the allowlist key covering this mismatch, or None (= unexpected)."""
    if field == "labelhash" and (zv is None) != (sv is None):
        return "labelhash:null-vs-value"
    if field == "isWrapped" and sv and not zv:
        # subgraph says wrapped, zigens says not: the stale-wrap class.
        return "isWrapped:subgraph-stale-wrap"
    return None


def main() -> int:
    if not ZIGENS or not SUBGRAPH:
        print("PARITY_ZIGENS_URL / PARITY_SUBGRAPH_URL not set - skipping (not a failure).")
        return 0

    sampled = gql(ZIGENS, SAMPLE_QUERY, {"n": SAMPLE}).get("registrations") or []
    # The subgraph's domain(id:) takes a namehash; zigens accepts either. Compare
    # by namehash so both sides resolve identically.
    targets = [(r["name"], r["domain"]["id"]) for r in sampled
               if r.get("name") and (r.get("domain") or {}).get("id")]
    for n in FIXED:
        if namehash is not None:
            targets.insert(0, (n, namehash(n)))
    if not targets:
        print("no V1 registrations sampled - is this endpoint a V1-indexing deployment? "
              "(the reference subgraph indexes V1 only; a V2-only endpoint has nothing to compare)")
        return 1

    unexpected: list[str] = []
    allowed: list[str] = []
    checked = 0
    for name, node in targets:
        try:
            z = normalize("zigens", gql(ZIGENS, ZIGENS_QUERY, {"id": node}).get("domain"))
            s = normalize("subgraph", gql(SUBGRAPH, SUBGRAPH_QUERY, {"id": node}).get("domain"))
        except Exception as e:  # noqa: BLE001 - any endpoint hiccup is a finding, not a crash
            unexpected.append(f"{name}: query error: {e}")
            continue
        checked += 1
        if z is not None and z.pop("protocol", None) not in (None, "v1"):
            continue  # a V2 row shadows this namehash; not subgraph-comparable
        if z is None or s is None:
            if z != s:
                unexpected.append(f"{name}: present on one side only (zigens={z is not None}, subgraph={s is not None})")
            continue
        for field in z:
            if z[field] == s[field]:
                continue
            key = classify(field, z[field], s[field])
            line = f"{name}.{field}: zigens={z[field]!r} subgraph={s[field]!r}"
            if key in ALLOWLIST:
                allowed.append(f"{line} [allowed: {key}]")
            else:
                unexpected.append(line)

    print(f"parity: {checked} names checked, {len(allowed)} allowed divergences, {len(unexpected)} unexpected")
    for line in allowed:
        print(f"  ALLOWED  {line}")
    for line in unexpected:
        print(f"  DIVERGED {line}")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a") as f:
            f.write(f"## Subgraph parity\n\n{checked} names checked, "
                    f"{len(allowed)} allowed, **{len(unexpected)} unexpected**\n\n")
            for line in unexpected:
                f.write(f"- `{line}`\n")

    return 0 if len(unexpected) <= MAX_FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
