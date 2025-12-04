#!/usr/bin/env python3
"""Query NewSubname events from UserRegistry."""

import json
import urllib.request

RPC_URL = "https://eth-sepolia.g.alchemy.com/v2/YOUR_ALCHEMY_API_KEY"
USER_REGISTRY = "0x1a27f4cf2ff1489f2c33d694e33a578d543a6ef7"
NEW_SUBNAME_SIG = "0x951e26484e0e5489d2a90627adef6bfd545d85b240ebe2630413776887135ee9"
FROM_BLOCK = 9524688
TO_BLOCK = 9524830

def make_rpc_call(method, params):
    """Make JSON-RPC call."""
    payload = {
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1
    }

    req = urllib.request.Request(
        RPC_URL,
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )

    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read().decode('utf-8'))

print(f"Querying NewSubname events from UserRegistry {USER_REGISTRY}")
print(f"Block range: {FROM_BLOCK} - {TO_BLOCK}")
print(f"Event signature: {NEW_SUBNAME_SIG}")
print("=" * 80)

# Query eth_getLogs
result = make_rpc_call("eth_getLogs", [{
    "fromBlock": hex(FROM_BLOCK),
    "toBlock": hex(TO_BLOCK),
    "address": USER_REGISTRY,
    "topics": [NEW_SUBNAME_SIG]
}])

if "error" in result:
    print(f"❌ Error: {result['error']}")
    exit(1)

logs = result.get("result", [])
print(f"\nFound {len(logs)} NewSubname event(s):\n")

if len(logs) == 0:
    print("❌ No NewSubname events found!")
    print("\nPossible reasons:")
    print("  1. Events might use a different signature")
    print("  2. UserRegistry might not emit NewSubname")
    print("  3. Block range might be wrong")
    print("\nLet's query ALL events from UserRegistry in this range...")

    result2 = make_rpc_call("eth_getLogs", [{
        "fromBlock": hex(FROM_BLOCK),
        "toBlock": hex(TO_BLOCK),
        "address": USER_REGISTRY
    }])

    all_logs = result2.get("result", [])
    print(f"\nFound {len(all_logs)} total events from UserRegistry")

    if len(all_logs) > 0:
        print("\nEvent signatures found:")
        sigs = {}
        for log in all_logs:
            sig = log['topics'][0]
            sigs[sig] = sigs.get(sig, 0) + 1
        for sig, count in sigs.items():
            print(f"  {sig}: {count} event(s)")
else:
    for i, log in enumerate(logs):
        print(f"Event #{i}:")
        print(f"  Block: {int(log['blockNumber'], 16)}")
        print(f"  Tx: {log['transactionHash']}")
        print(f"  Topics: {log['topics']}")
        print(f"  Data: {log['data'][:66]}...")
        print()
