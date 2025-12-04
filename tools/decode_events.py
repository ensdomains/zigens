#!/usr/bin/env python3
"""Decode event signatures from the transaction."""

import hashlib

def keccak256(text):
    """Calculate Keccak-256 hash (Ethereum uses Keccak, not SHA3)."""
    from Crypto.Hash import keccak
    k = keccak.new(digest_bits=256)
    k.update(text.encode('utf-8'))
    return '0x' + k.hexdigest()

# Known ENS event signatures
events = {
    "NameRegistered(uint256,string,uint64,address)": None,
    "NameRenewed(uint256,uint64,address)": None,
    "NameBurned(uint256,address)": None,
    "SubregistryUpdate(uint256,address)": None,
    "ResolverUpdate(uint256,address)": None,
    "TokenRegenerated(uint256,uint256)": None,
    "TokenObserverSet(uint256,address)": None,
    "Transfer(address,address,uint256)": None,  # ERC721
    "TransferSingle(address,address,address,uint256,uint256)": None,  # ERC1155
}

print("Event Signature Hashes:")
print("=" * 80)
for sig in events:
    hash_val = keccak256(sig)
    events[sig] = hash_val
    print(f"{sig}")
    print(f"  → {hash_val}")
    print()

# Events we found in the transaction
found_events = [
    "0x829711ca32bda05a6295424f2810a1d378f1c64d3984efa22f32237c492920d2",
    "0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62",
    "0x57e0443e1e4275db3a8ed8072395c6f866bb0572818883017f3bdfa52e16179f",
    "0x951e26484e0e5489d2a90627adef6bfd545d85b240ebe2630413776887135ee9",
]

print("\nMatching found events:")
print("=" * 80)
for found in found_events:
    print(f"\n{found}:")
    matched = False
    for sig, hash_val in events.items():
        if hash_val == found:
            print(f"  ✅ Matches: {sig}")
            matched = True
            break
    if not matched:
        print(f"  ❌ No match - unknown event")
