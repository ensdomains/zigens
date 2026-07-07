CONTRACT MANIFESTS (Task 08 — config as data)
================================================================================

These .zon files declare the ENS contract wiring (addresses + deployment blocks)
for a network as DATA, so a redeployment or proxy change is a config edit rather
than a code change + rebuild + redeploy.

USAGE
--------------------------------------------------------------------------------
Set MANIFEST_PATH to a manifest file and the API/indexer load contract wiring
from it instead of the hardcoded src/contracts.zig switch:

    MANIFEST_PATH=manifests/sepolia.zon

When MANIFEST_PATH is empty (the default), behavior is byte-identical to before —
the code switch (getContractAddresses) is used. Adopt gradually: point staging at
a reference manifest, confirm identical indexing, then use a manifest edit for the
next redeployment instead of a code change.

FORMAT
--------------------------------------------------------------------------------
    .{
        .manifest_version = 1,
        .chain_id = 11155111,          // MUST match NETWORK's chain id
        .contracts = .{
            .{ .name = "ens_registry", .address = "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e" },
            .{ .name = "eth_label_store", .address = "0x...", .status = .disabled },
            ...
        },
        .blocks = .{
            .v1_deployment_block = 10893210,
            .v2_deployment_block = 11163314,
            .temp_registrar_start_block = 0,
            .v1_migration_block = 0,
            .name_wrapper_deployment_block = 0,
        },
    }

Per-contract fields:
  name        (required) a known address field of src/contracts.zig ContractAddresses.
              An unknown name fails startup — this catches typos.
  address     (required) 0x-prefixed 20-byte hex. Use the zero address for a
              contract not deployed on this network.
  status      (optional, default .active) active | shadow | disabled. `disabled`
              forces the address to zero, which the indexer already skips.
  start_block (optional) per-contract sync start; informational in v1.

Every contract must be declared explicitly (with the zero address if not deployed
on this network, or status = .disabled). OMITTING a contract is an error — this
prevents a dropped/typo'd line from silently removing a contract from the indexed
set. The committed reference manifests list all contracts, so they are a safe
starting point to edit.

VALIDATION (fail-fast at startup, never a silent mis-index)
--------------------------------------------------------------------------------
  - chain_id must equal the NETWORK's chain id.
  - every address must be well-formed 0x hex.
  - every contract name must be a real ContractAddresses field.
  - every contract must be declared (no omissions).
  - no duplicate contract names.

ADDING A REDEPLOYMENT
--------------------------------------------------------------------------------
Edit the address of the redeployed contract (and the relevant .blocks entry if the
deployment block changed). No recompile. Restart with MANIFEST_PATH pointing here.

REGENERATING THE REFERENCE MANIFESTS
--------------------------------------------------------------------------------
These files are generated from the current src/contracts.zig defaults; a test
(test-manifest) asserts they load to exactly the code defaults, so they can't drift
silently. To regenerate after a code change:

    MANIFEST_GEN=1 zig build test-manifest
