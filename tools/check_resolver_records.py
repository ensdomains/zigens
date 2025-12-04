#!/usr/bin/env python3
"""Check resolver records via RPC."""

import json
import urllib.request

RPC_URL = "https://eth-sepolia.g.alchemy.com/v2/YOUR_ALCHEMY_API_KEY"
RESOLVER = "0xaf19ac62dd9b1787edace154769db916ed8ece75"
NAMEHASH = "0xd1ec3eb174abaa5fc6aa3e4bd52f9cde80571c15233b17d192d0a9e5fa6e2eca"  # sub1761849494891.lifecycle1761849494891.eth

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

print(f"Checking resolver records for subname")
print(f"Resolver: {RESOLVER}")
print(f"Namehash: {NAMEHASH}")
print("=" * 80)

# addr(bytes32) - function signature: 0x3b3b57de
# This returns the ETH address record (coinType 60)
print("\n1. Checking ETH address (coinType 60)...")
result = make_rpc_call("eth_call", [{
    "to": RESOLVER,
    "data": "0x3b3b57de" + NAMEHASH[2:]  # addr(bytes32)
}, "latest"])

if "result" in result and result["result"] != "0x":
    addr_data = result["result"]
    # Decode address from bytes32 (last 20 bytes)
    if len(addr_data) >= 66:
        address = "0x" + addr_data[-40:]
        print(f"   ✅ ETH Address set: {address}")
    else:
        print(f"   ❌ No ETH address set (returned: {addr_data})")
else:
    print(f"   ❌ Error or no address: {result}")

# text(bytes32,string) - function signature: 0x59d1d43c
# Check for common text records
text_keys = ["avatar", "description", "email", "url", "com.twitter", "com.github"]

print(f"\n2. Checking text records...")
for key in text_keys:
    # Encode: 0x59d1d43c + namehash + offset(32 bytes) + length + padded_key
    key_hex = key.encode('utf-8').hex()
    key_len = len(key)
    key_len_hex = format(key_len, '064x')
    key_padded = key_hex + '0' * (64 - len(key_hex))

    data = "0x59d1d43c" + NAMEHASH[2:] + "0000000000000000000000000000000000000000000000000000000000000040" + key_len_hex + key_padded

    result = make_rpc_call("eth_call", [{
        "to": RESOLVER,
        "data": data
    }, "latest"])

    if "result" in result and result["result"] != "0x" and len(result["result"]) > 130:
        # Decode the response
        try:
            # Skip first 64 chars (0x + offset), next 64 chars is length
            length_hex = result["result"][66:130]
            length = int(length_hex, 16)
            if length > 0:
                value_hex = result["result"][130:130 + length * 2]
                value = bytes.fromhex(value_hex).decode('utf-8')
                print(f"   ✅ {key}: {value}")
        except:
            pass

print(f"\n3. Checking contenthash...")
# contenthash(bytes32) - function signature: 0xbc1c58d1
result = make_rpc_call("eth_call", [{
    "to": RESOLVER,
    "data": "0xbc1c58d1" + NAMEHASH[2:]
}, "latest"])

if "result" in result and result["result"] != "0x" and len(result["result"]) > 130:
    print(f"   ✅ Contenthash set: {result['result']}")
else:
    print(f"   ❌ No contenthash set")

print("\n" + "=" * 80)
print("Summary: If all show ❌, then no records are set on-chain (indexer is correct)")
