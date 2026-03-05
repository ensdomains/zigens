-- Resolver record storage tables (OwnedResolver support)
-- Stores aliases, pubkeys, ABIs, reverse names, interfaces, and version tracking

-- Resolver aliases (from OwnedResolver AliasChanged events)
-- Maps fromName → toName per resolver contract
-- Aliases are NOT versioned (not cleared by VersionChanged)
CREATE TABLE IF NOT EXISTS resolver_aliases (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    resolver TEXT NOT NULL,
    from_name TEXT NOT NULL,
    to_name TEXT NOT NULL,
    chain TEXT NOT NULL,
    block_number INTEGER NOT NULL,
    transaction_hash TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    UNIQUE(resolver, from_name)
);
CREATE INDEX IF NOT EXISTS idx_resolver_aliases_resolver ON resolver_aliases(resolver);

-- Resolver pubkey records (from PubkeyChanged events)
CREATE TABLE IF NOT EXISTS resolver_pubkeys (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    namehash TEXT NOT NULL UNIQUE,
    resolver TEXT NOT NULL,
    x TEXT NOT NULL,
    y TEXT NOT NULL,
    chain TEXT NOT NULL,
    block_number INTEGER NOT NULL,
    transaction_hash TEXT NOT NULL,
    timestamp INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_resolver_pubkeys_namehash ON resolver_pubkeys(namehash);

-- Resolver ABI records (from ABIChanged events)
CREATE TABLE IF NOT EXISTS resolver_abis (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    namehash TEXT NOT NULL,
    resolver TEXT NOT NULL,
    content_type INTEGER NOT NULL,
    chain TEXT NOT NULL,
    block_number INTEGER NOT NULL,
    transaction_hash TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    UNIQUE(namehash, content_type)
);
CREATE INDEX IF NOT EXISTS idx_resolver_abis_namehash ON resolver_abis(namehash);

-- Resolver name records (from NameChanged events, for reverse resolution)
CREATE TABLE IF NOT EXISTS resolver_names (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    namehash TEXT NOT NULL UNIQUE,
    resolver TEXT NOT NULL,
    name TEXT NOT NULL,
    chain TEXT NOT NULL,
    block_number INTEGER NOT NULL,
    transaction_hash TEXT NOT NULL,
    timestamp INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_resolver_names_namehash ON resolver_names(namehash);

-- Resolver interface records (from InterfaceChanged events)
CREATE TABLE IF NOT EXISTS resolver_interfaces (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    namehash TEXT NOT NULL,
    resolver TEXT NOT NULL,
    interface_id TEXT NOT NULL,
    implementer TEXT NOT NULL,
    chain TEXT NOT NULL,
    block_number INTEGER NOT NULL,
    transaction_hash TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    UNIQUE(namehash, interface_id)
);
CREATE INDEX IF NOT EXISTS idx_resolver_interfaces_namehash ON resolver_interfaces(namehash);

-- Resolver version tracking (from VersionChanged events)
CREATE TABLE IF NOT EXISTS resolver_versions (
    namehash TEXT NOT NULL PRIMARY KEY,
    resolver TEXT NOT NULL,
    version INTEGER NOT NULL,
    chain TEXT NOT NULL,
    block_number INTEGER NOT NULL,
    transaction_hash TEXT NOT NULL,
    timestamp INTEGER NOT NULL
);
