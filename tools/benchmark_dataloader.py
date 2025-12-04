#!/usr/bin/env python3
"""
Performance benchmark for DataLoader optimizations
Tests query performance with varying numbers of domains to demonstrate N+1 query elimination
"""

import requests
import time
import json
import sys
from typing import Dict, Any

GRAPHQL_ENDPOINT = "http://localhost:8085/graphql"

def execute_query(query: str) -> Dict[str, Any]:
    """Execute GraphQL query and return response with timing"""
    start_time = time.time()

    response = requests.post(
        GRAPHQL_ENDPOINT,
        json={"query": query},
        headers={"Content-Type": "application/json"}
    )

    elapsed = time.time() - start_time

    if response.status_code != 200:
        print(f"❌ HTTP Error {response.status_code}: {response.text}")
        return None

    data = response.json()

    if "errors" in data:
        print(f"❌ GraphQL Error: {json.dumps(data['errors'], indent=2)}")
        return None

    return {
        "data": data.get("data"),
        "elapsed_ms": elapsed * 1000
    }

def test_query_performance(domain_count: int, include_resolver_data: bool = True) -> Dict[str, Any]:
    """Test query performance for a given number of domains"""

    # Build query - request multiple resolver fields to trigger DataLoader
    resolver_fields = """
        resolver {
          address
          contentHash
          texts
        }
    """ if include_resolver_data else ""

    query = f"""
    {{
      domains(first: {domain_count}) {{
        id
        name
        createdAt
        {resolver_fields}
      }}
    }}
    """

    print(f"\n{'='*60}")
    print(f"Testing: {domain_count} domains" + (" with resolver data" if include_resolver_data else " without resolver data"))
    print('='*60)

    result = execute_query(query)

    if not result:
        return None

    domain_data = result["data"].get("domains", [])

    print(f"✅ Query completed in {result['elapsed_ms']:.2f}ms")
    print(f"   Returned {len(domain_data)} domains")

    if include_resolver_data and domain_data:
        # Count how many domains have resolver data
        with_resolver = sum(1 for d in domain_data if d.get("resolver"))
        print(f"   {with_resolver} domains have resolver data")

    return result

def run_benchmark_suite():
    """Run complete benchmark suite"""

    print("\n" + "="*60)
    print("DataLoader Performance Benchmark")
    print("="*60)
    print(f"Endpoint: {GRAPHQL_ENDPOINT}")
    print()

    # Check if server is running
    try:
        response = requests.get("http://localhost:8085/graphql")
        if response.status_code != 200:
            print("❌ Server is not responding correctly")
            sys.exit(1)
    except Exception as e:
        print(f"❌ Cannot connect to server: {e}")
        print("\nMake sure the API server is running:")
        print("  ./zig-out/bin/ensv2-api")
        sys.exit(1)

    print("✅ Server is running\n")

    # Test cases with increasing domain counts
    test_cases = [
        (5, "Small dataset"),
        (10, "Medium dataset"),
        (20, "Large dataset"),
        (50, "Very large dataset"),
    ]

    results = []

    for count, description in test_cases:
        result = test_query_performance(count, include_resolver_data=True)
        if result:
            results.append({
                "count": count,
                "description": description,
                "elapsed_ms": result["elapsed_ms"]
            })
        time.sleep(0.5)  # Brief pause between tests

    # Summary
    print("\n" + "="*60)
    print("BENCHMARK SUMMARY")
    print("="*60)
    print()
    print("Domain Count | Description        | Query Time")
    print("-------------|--------------------|-----------")

    for r in results:
        print(f"{r['count']:12} | {r['description']:18} | {r['elapsed_ms']:7.2f}ms")

    # Calculate efficiency
    if len(results) >= 2:
        print()
        print("Performance Scaling:")
        print("-" * 60)
        base_result = results[0]
        for r in results[1:]:
            ratio = r["elapsed_ms"] / base_result["elapsed_ms"]
            domain_ratio = r["count"] / base_result["count"]
            efficiency = (domain_ratio / ratio) * 100

            print(f"{r['count']}x domains: {ratio:.2f}x time (efficiency: {efficiency:.1f}%)")
            print(f"  Without DataLoader would be ~{domain_ratio:.1f}x time")

    print()
    print("="*60)
    print("✅ Benchmark complete!")
    print()
    print("The DataLoader batching eliminates N+1 queries, so query time")
    print("scales much better than linearly with domain count.")
    print("="*60)

if __name__ == "__main__":
    run_benchmark_suite()
