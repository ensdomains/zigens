#!/usr/bin/env python3
"""Find ALL resolver events from the resolver contract (any node)."""

import json
import urllib.request

RPC_URL = "https://eth-sepolia.g.alchemy.com/v2/YOUR_ALCHEMY_API_KEY"
RESOLVER = "0xaf19ac62dd9b1787edace154769db916ed8ece75"
EXPECTED_NAMEHASH = "0xd1ec3eb174abaa5fc6aa3e4bd52f9cde80571c15233b17d192d0a9e5fa6e2eca"

# Event signatures
ADDRESS_CHANGED = "0x65412581168e88a1e60c6459d7f44ae83ad0832e670826c05a4e2476b57af752"  # AddressChanged(bytes32,uint256,bytes)
TEXT_CHANGED = "0x448bc014f1536726cf8d54ff3d6481ed3cbc683c2591ca204274009afa09b1a1"  # TextChanged(bytes32,string,string,string)

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

print(f"Searching for ALL resolver events from resolver...")
print(f"Resolver: {RESOLVER}")
print(f"Expected namehash: {EXPECTED_NAMEHASH}")
print("=" * 80)

# Search from block 9524691 (when subname was created) onwards
FROM_BLOCK = 9524691

# Get current block
current_block_result = make_rpc_call("eth_blockNumber", [])
TO_BLOCK = int(current_block_result["result"], 16)

print(f"Searching blocks {FROM_BLOCK} to {TO_BLOCK}")

print(f"\n1. Searching for ALL AddressChanged events (any node)...")
result = make_rpc_call("eth_getLogs", [{
    "fromBlock": hex(FROM_BLOCK),
    "toBlock": hex(TO_BLOCK),
    "address": RESOLVER,
    "topics": [ADDRESS_CHANGED]  # No node filter - get ALL
}])

addr_logs = result.get("result", [])
print(f"   Found {len(addr_logs)} AddressChanged event(s)")
for i, log in enumerate(addr_logs):
    block = int(log['blockNumber'], 16)
    node = log['topics'][1] if len(log['topics']) > 1 else "N/A"
    match = "✅ MATCH!" if node.lower() == EXPECTED_NAMEHASH.lower() else f"❌ Wrong node: {node}"
    print(f"   Event #{i}: Block {block}, Tx {log['transactionHash'][:10]}..., {match}")

print(f"\n2. Searching for ALL TextChanged events (any node)...")
result = make_rpc_call("eth_getLogs", [{
    "fromBlock": hex(FROM_BLOCK),
    "toBlock": hex(TO_BLOCK),
    "address": RESOLVER,
    "topics": [TEXT_CHANGED]  # No node filter - get ALL
}])

text_logs = result.get("result", [])
print(f"   Found {len(text_logs)} TextChanged event(s)")
for i, log in enumerate(text_logs):
    block = int(log['blockNumber'], 16)
    node = log['topics'][1] if len(log['topics']) > 1 else "N/A"
    match = "✅ MATCH!" if node.lower() == EXPECTED_NAMEHASH.lower() else f"❌ Wrong node: {node}"
    print(f"   Event #{i}: Block {block}, Tx {log['transactionHash'][:10]}..., {match}")

print("\n" + "=" * 80)
if len(addr_logs) > 0 or len(text_logs) > 0:
    print("Events found! Check if they use the correct namehash or 0x0")
else:
    print("No events at all - records might be set via storage writes without events")
