#!/usr/bin/env python3
"""
Query transaction events from RPC to debug why subname isn't indexed.

Transaction: 0xb1288cf6a129ac49f5fc6975fa3fc80ceb63ea34c1ff38db55b592a52223ea8a
UserRegistry: 0x1a27f4cf2ff1489f2c33d694e33a578d543a6ef7
Expected event: NameRegistered(bytes32 indexed parentHash, bytes32 indexed labelhash, ...)
"""

import json
import urllib.request
import sys

# RPC endpoint (Alchemy Sepolia)
RPC_URLS = [
    "https://eth-sepolia.g.alchemy.com/v2/YOUR_ALCHEMY_API_KEY",
]

TX_HASH = "0xb1288cf6a129ac49f5fc6975fa3fc80ceb63ea34c1ff38db55b592a52223ea8a"
USER_REGISTRY = "0x1a27f4cf2ff1489f2c33d694e33a578d543a6ef7".lower()
NAME_REGISTERED_SIG = "0xd9d0e8edd77eacdd7bd3f1d10259814b1aa244f74019f036046bbcc622fdcf59"

def make_rpc_call(rpc_url, method, params):
    """Make JSON-RPC call to Ethereum node."""
    payload = {
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1
    }

    req = urllib.request.Request(
        rpc_url,
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return json.loads(response.read().decode('utf-8'))
    except Exception as e:
        return {"error": str(e)}

def query_transaction(tx_hash):
    """Query transaction receipt and logs."""
    print(f"Querying transaction: {tx_hash}")
    print("=" * 80)

    # Try each RPC endpoint
    for rpc_url in RPC_URLS:
        print(f"\nTrying RPC: {rpc_url}")

        # Get transaction receipt
        result = make_rpc_call(rpc_url, "eth_getTransactionReceipt", [tx_hash])

        if "error" in result:
            print(f"  ❌ Error: {result['error']}")
            continue

        if "result" not in result or result["result"] is None:
            print(f"  ❌ No result returned")
            continue

        receipt = result["result"]
        print(f"  ✅ Connected successfully!")
        print(f"\nTransaction Details:")
        print(f"  Block Number: {int(receipt['blockNumber'], 16)}")
        print(f"  Status: {'Success' if int(receipt['status'], 16) == 1 else 'Failed'}")
        print(f"  Gas Used: {int(receipt['gasUsed'], 16)}")
        print(f"  Logs: {len(receipt['logs'])} events emitted")

        # Analyze logs
        print(f"\n{'='*80}")
        print(f"EVENT ANALYSIS")
        print(f"{'='*80}")

        user_registry_events = []
        all_events = []

        for i, log in enumerate(receipt['logs']):
            log_address = log['address'].lower()
            topics = log['topics']

            event_info = {
                'index': i,
                'address': log['address'],
                'topics': topics,
                'data': log['data']
            }
            all_events.append(event_info)

            # Check if from UserRegistry
            if log_address == USER_REGISTRY:
                user_registry_events.append(event_info)

        print(f"\nAll Events ({len(all_events)}):")
        print("-" * 80)
        for event in all_events:
            print(f"\nEvent #{event['index']}:")
            print(f"  Contract: {event['address']}")
            print(f"  Topics ({len(event['topics'])}):")
            for j, topic in enumerate(event['topics']):
                marker = " ← NameRegistered!" if topic == NAME_REGISTERED_SIG else ""
                print(f"    [{j}] {topic}{marker}")
            print(f"  Data: {event['data'][:66]}..." if len(event['data']) > 66 else f"  Data: {event['data']}")

        print(f"\n{'='*80}")
        print(f"UserRegistry Events (from {USER_REGISTRY}):")
        print(f"{'='*80}")
        if user_registry_events:
            print(f"Found {len(user_registry_events)} event(s) from UserRegistry:\n")
            for event in user_registry_events:
                print(f"Event #{event['index']}:")
                print(f"  Topics: {event['topics']}")
                print(f"  Data: {event['data']}")

                if event['topics'][0] == NAME_REGISTERED_SIG:
                    print(f"  ✅ This IS a NameRegistered event!")
                else:
                    print(f"  ⚠️  This is NOT a NameRegistered event")
                    print(f"     Expected: {NAME_REGISTERED_SIG}")
                    print(f"     Got:      {event['topics'][0]}")
        else:
            print("❌ NO events emitted from UserRegistry!")
            print(f"\nThis explains why the subname wasn't indexed.")
            print(f"Possible reasons:")
            print(f"  1. Transaction failed (check status)")
            print(f"  2. UserRegistry address is wrong")
            print(f"  3. Event was emitted from a different contract")
            print(f"  4. UserRegistry uses different event signature")

        return True

    print("\n❌ Failed to connect to any RPC endpoint")
    return False

if __name__ == "__main__":
    success = query_transaction(TX_HASH)
    sys.exit(0 if success else 1)
