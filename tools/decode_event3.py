#!/usr/bin/env python3
"""Decode event #3 data."""

# Event #3 data from the transaction
data = "0x000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000107375623137363138343934393438393100000000000000000000000000000000"

# Remove 0x prefix
hex_data = data[2:]

# First 32 bytes (64 hex chars) = offset to string (0x20 = 32)
offset = int(hex_data[0:64], 16)
print(f"Offset: {offset}")

# Next 32 bytes = string length
length = int(hex_data[64:128], 16)
print(f"Length: {length}")

# Remaining bytes = string data
string_hex = hex_data[128:128 + length * 2]
string_val = bytes.fromhex(string_hex).decode('utf-8')
print(f"String: '{string_val}'")

print("\nThis confirms event #3 contains the label 'sub1761849494891'")
print("But what event is it? Let me try some guesses...")

from Crypto.Hash import keccak

def keccak256(text):
    k = keccak.new(digest_bits=256)
    k.update(text.encode('utf-8'))
    return '0x' + k.hexdigest()

# Try various event signatures that might contain a label
guesses = [
    "LabelRegistered(uint256,string)",
    "NameCreated(uint256,string)",
    "SubnameCreated(uint256,string)",
    "NewSubname(uint256,string)",
    "LabelSet(uint256,string)",
    "NameSet(uint256,string)",
]

target = "0x951e26484e0e5489d2a90627adef6bfd545d85b240ebe2630413776887135ee9"

print(f"\nSearching for event signature {target}...")
for guess in guesses:
    hash_val = keccak256(guess)
    match = "✅ MATCH!" if hash_val == target else ""
    print(f"  {guess}: {hash_val} {match}")
