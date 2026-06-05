#!/usr/bin/env python3
# Generate GraphQL introspection JSON from schema.graphql.
#
# Tokenizer + recursive-descent parser. No regex SDL parsing, no
# external dependencies. Replaces the prior regex-based parser which
# silently truncated docstrings with embedded quotes and used naming
# heuristics ("ends with Filter") that misclassified types.
#
# Supported SDL features (matches what schema.graphql uses):
#   * `type X { ... }`, `input X { ... }`, `enum X { ... }`
#   * Block-string descriptions attached to types, fields, args, and
#     enum values; quotes inside descriptions are tolerated.
#   * Field args with optional default values (e.g. `arg: Type = "default"`).
#   * Type modifiers: `Type`, `Type!`, `[Type]`, `[Type!]!`, etc.
#   * Hash comments (`# ...`).
#
# Not supported (intentionally — schema.graphql doesn't use them):
#   * `interface`, `union`, `scalar`, `extend`, `directive`,
#     `implements`, `schema { ... }`.
#   * Triple-quote escape sequences inside block strings.
from __future__ import annotations

import json
import os
import sys
import unittest
from dataclasses import dataclass, field
from typing import Any


# ---------------------------------------------------------------------------
# Tokenizer
# ---------------------------------------------------------------------------

# Token kinds: NAME (identifier), PUNCT (single-char punctuation),
# DESC (block-string description), STR (single-line string, used in defaults),
# NUM (numeric default), EOF.
@dataclass
class Token:
    kind: str
    value: str
    line: int


PUNCTUATION = set("{}()[]:,!=")


def tokenize(src: str) -> list[Token]:
    tokens: list[Token] = []
    i = 0
    line = 1
    n = len(src)

    while i < n:
        c = src[i]

        # Whitespace / newlines
        if c in " \t\r":
            i += 1
            continue
        if c == "\n":
            line += 1
            i += 1
            continue

        # Hash comment to end of line
        if c == "#":
            while i < n and src[i] != "\n":
                i += 1
            continue

        # Block string description: """ ... """
        if c == '"' and i + 2 < n and src[i + 1] == '"' and src[i + 2] == '"':
            start_line = line
            i += 3
            buf: list[str] = []
            while i + 2 < n:
                if src[i] == '"' and src[i + 1] == '"' and src[i + 2] == '"':
                    i += 3
                    tokens.append(Token("DESC", "".join(buf).strip(), start_line))
                    break
                if src[i] == "\n":
                    line += 1
                buf.append(src[i])
                i += 1
            else:
                raise SyntaxError(f"Unterminated block string at line {start_line}")
            continue

        # Single-line string (used in default values)
        if c == '"':
            start_line = line
            i += 1
            buf = []
            while i < n and src[i] != '"':
                if src[i] == "\n":
                    raise SyntaxError(f"Unterminated string at line {start_line}")
                if src[i] == "\\" and i + 1 < n:
                    buf.append(src[i])
                    buf.append(src[i + 1])
                    i += 2
                    continue
                buf.append(src[i])
                i += 1
            if i >= n:
                raise SyntaxError(f"Unterminated string at line {start_line}")
            i += 1  # closing "
            tokens.append(Token("STR", "".join(buf), start_line))
            continue

        # Identifier
        if c.isalpha() or c == "_":
            start = i
            while i < n and (src[i].isalnum() or src[i] == "_"):
                i += 1
            tokens.append(Token("NAME", src[start:i], line))
            continue

        # Number (used in default values)
        if c.isdigit() or (c == "-" and i + 1 < n and src[i + 1].isdigit()):
            start = i
            i += 1
            while i < n and (src[i].isdigit() or src[i] == "."):
                i += 1
            tokens.append(Token("NUM", src[start:i], line))
            continue

        # Punctuation
        if c in PUNCTUATION:
            tokens.append(Token("PUNCT", c, line))
            i += 1
            continue

        raise SyntaxError(f"Unexpected character {c!r} at line {line}")

    tokens.append(Token("EOF", "", line))
    return tokens


# ---------------------------------------------------------------------------
# Parser — produces an AST as plain dicts ready for introspection emission.
# ---------------------------------------------------------------------------


@dataclass
class Parser:
    tokens: list[Token]
    pos: int = 0

    def peek(self, offset: int = 0) -> Token:
        return self.tokens[self.pos + offset]

    def eat(self, kind: str, value: str | None = None) -> Token:
        tok = self.peek()
        if tok.kind != kind or (value is not None and tok.value != value):
            expected = f"{kind}({value!r})" if value is not None else kind
            raise SyntaxError(f"Expected {expected}, got {tok.kind}({tok.value!r}) at line {tok.line}")
        self.pos += 1
        return tok

    def accept(self, kind: str, value: str | None = None) -> Token | None:
        tok = self.peek()
        if tok.kind != kind:
            return None
        if value is not None and tok.value != value:
            return None
        self.pos += 1
        return tok

    def consume_descriptions(self) -> str | None:
        # Schemas occasionally have stray/duplicate description blocks before
        # a definition (e.g., a leftover annotation). The GraphQL spec ties
        # exactly one description string to its definition; when multiple
        # appear in a row, we keep the last (the one nearest the keyword).
        last: str | None = None
        while self.peek().kind == "DESC":
            last = self.eat("DESC").value
        return last

    def parse_document(self) -> list[dict[str, Any]]:
        types: list[dict[str, Any]] = []
        while self.peek().kind != "EOF":
            description = self.consume_descriptions()
            kw = self.eat("NAME").value
            if kw == "type":
                types.append(self.parse_object(description))
            elif kw == "input":
                types.append(self.parse_input(description))
            elif kw == "enum":
                types.append(self.parse_enum(description))
            else:
                raise SyntaxError(
                    f"Unsupported top-level keyword {kw!r} at line {self.peek(-1).line}. "
                    "Add support if the schema starts using it."
                )
        return types

    def parse_object(self, description: str | None) -> dict[str, Any]:
        name = self.eat("NAME").value
        self.eat("PUNCT", "{")
        fields = []
        while not self.accept("PUNCT", "}"):
            fields.append(self.parse_field())
        return {
            "kind": "OBJECT",
            "name": name,
            "description": description,
            "interfaces": [],
            "fields": fields,
        }

    def parse_input(self, description: str | None) -> dict[str, Any]:
        name = self.eat("NAME").value
        self.eat("PUNCT", "{")
        input_fields = []
        while not self.accept("PUNCT", "}"):
            input_fields.append(self.parse_input_field())
        return {
            "kind": "INPUT_OBJECT",
            "name": name,
            "description": description,
            "inputFields": input_fields,
        }

    def parse_enum(self, description: str | None) -> dict[str, Any]:
        name = self.eat("NAME").value
        self.eat("PUNCT", "{")
        values = []
        while not self.accept("PUNCT", "}"):
            value_desc = self.consume_descriptions()
            value_name = self.eat("NAME").value
            values.append({
                "name": value_name,
                "description": value_desc,
                "isDeprecated": False,
                "deprecationReason": None,
            })
        return {
            "kind": "ENUM",
            "name": name,
            "description": description,
            "enumValues": values,
        }

    def parse_field(self) -> dict[str, Any]:
        # field: optional description, name, optional (args), `:`, type
        desc_value = self.consume_descriptions()
        field_name = self.eat("NAME").value
        args = []
        if self.accept("PUNCT", "("):
            while not self.accept("PUNCT", ")"):
                args.append(self.parse_arg())
                self.accept("PUNCT", ",")
        self.eat("PUNCT", ":")
        field_type = self.parse_type()
        return {
            "name": field_name,
            "description": desc_value,
            "args": args,
            "type": field_type,
            "isDeprecated": False,
            "deprecationReason": None,
        }

    def parse_input_field(self) -> dict[str, Any]:
        # input field: optional description, name, `:`, type, optional `=` default.
        desc_value = self.consume_descriptions()
        name = self.eat("NAME").value
        self.eat("PUNCT", ":")
        field_type = self.parse_type()
        # Skip default value if present — introspection captures it as defaultValue
        # (we don't emit it currently because the executor doesn't read it).
        if self.accept("PUNCT", "="):
            self.consume_default_value()
        return {
            "name": name,
            "description": desc_value,
            "type": field_type,
        }

    def parse_arg(self) -> dict[str, Any]:
        desc_value = self.consume_descriptions()
        name = self.eat("NAME").value
        self.eat("PUNCT", ":")
        arg_type = self.parse_type()
        if self.accept("PUNCT", "="):
            self.consume_default_value()
        return {
            "name": name,
            "description": desc_value,
            "type": arg_type,
        }

    def parse_type(self) -> dict[str, Any]:
        # `[T]` list / `T!` non-null / `T` named
        if self.accept("PUNCT", "["):
            inner = self.parse_type()
            self.eat("PUNCT", "]")
            wrapped: dict[str, Any] = {"kind": "LIST", "ofType": inner}
        else:
            name = self.eat("NAME").value
            wrapped = {"kind": "PLACEHOLDER", "name": name}
        if self.accept("PUNCT", "!"):
            return {"kind": "NON_NULL", "ofType": wrapped}
        return wrapped

    def consume_default_value(self) -> None:
        """Eat exactly one default-value token (literal, name, list, or string)."""
        tok = self.peek()
        if tok.kind in ("NUM", "STR"):
            self.pos += 1
            return
        if tok.kind == "NAME":
            self.pos += 1
            return
        if tok.kind == "PUNCT" and tok.value == "[":
            depth = 0
            while True:
                t = self.peek()
                if t.kind == "PUNCT" and t.value == "[":
                    depth += 1
                elif t.kind == "PUNCT" and t.value == "]":
                    depth -= 1
                    self.pos += 1
                    if depth == 0:
                        return
                    continue
                self.pos += 1
        else:
            raise SyntaxError(f"Unexpected default-value token {tok.kind}({tok.value!r}) at line {tok.line}")


# ---------------------------------------------------------------------------
# Introspection emitter
# ---------------------------------------------------------------------------

BUILTIN_SCALARS = {"String", "Int", "Boolean", "Float", "ID"}


def emit_introspection(types: list[dict[str, Any]]) -> dict[str, Any]:
    # Resolve PLACEHOLDER refs into proper SCALAR/ENUM/OBJECT/INPUT_OBJECT kinds
    # using the actual definitions we parsed.
    type_kinds = {BUILTIN: "SCALAR" for BUILTIN in BUILTIN_SCALARS}
    for t in types:
        type_kinds[t["name"]] = t["kind"]

    def resolve(node: dict[str, Any]) -> dict[str, Any]:
        if node["kind"] == "PLACEHOLDER":
            name = node["name"]
            kind = type_kinds.get(name, "OBJECT")  # fall back to OBJECT for forward refs
            return {"kind": kind, "name": name}
        if node["kind"] in ("LIST", "NON_NULL"):
            return {"kind": node["kind"], "ofType": resolve(node["ofType"])}
        return node

    def walk_args(args: list[dict[str, Any]]) -> list[dict[str, Any]]:
        out = []
        for a in args:
            out.append({
                "name": a["name"],
                "description": a.get("description"),
                "type": resolve(a["type"]),
            })
        return out

    out_types: list[dict[str, Any]] = []
    for t in types:
        if t["kind"] == "OBJECT":
            out_types.append({
                "kind": "OBJECT",
                "name": t["name"],
                "description": t.get("description"),
                "interfaces": [],
                "fields": [
                    {
                        "name": f["name"],
                        "description": f.get("description"),
                        "args": walk_args(f["args"]),
                        "type": resolve(f["type"]),
                        "isDeprecated": False,
                        "deprecationReason": None,
                    }
                    for f in t["fields"]
                ],
            })
        elif t["kind"] == "INPUT_OBJECT":
            out_types.append({
                "kind": "INPUT_OBJECT",
                "name": t["name"],
                "description": t.get("description"),
                "inputFields": [
                    {
                        "name": f["name"],
                        "description": f.get("description"),
                        "type": resolve(f["type"]),
                    }
                    for f in t["inputFields"]
                ],
            })
        elif t["kind"] == "ENUM":
            out_types.append({
                "kind": "ENUM",
                "name": t["name"],
                "description": t.get("description"),
                "enumValues": t["enumValues"],
            })
        else:
            out_types.append(t)

    out_types.extend([
        {"kind": "SCALAR", "name": s} for s in sorted(BUILTIN_SCALARS)
    ])

    return {
        "data": {
            "__schema": {
                "queryType": {"name": "Query"},
                "mutationType": None,
                "subscriptionType": None,
                "types": out_types,
                "directives": [],
            }
        }
    }


def parse_graphql_schema(schema_text: str) -> dict[str, Any]:
    tokens = tokenize(schema_text)
    parser = Parser(tokens)
    types = parser.parse_document()
    return emit_introspection(types)


# ---------------------------------------------------------------------------
# Tests — run with `python3 tools/generate_introspection.py --self-test`.
# ---------------------------------------------------------------------------


class IntrospectionTests(unittest.TestCase):
    def names_of(self, schema: str) -> set[str]:
        return {t["name"] for t in parse_graphql_schema(schema)["data"]["__schema"]["types"]}

    def test_basic_object_and_input(self) -> None:
        names = self.names_of("type Query { x: String } input FooFilter { name: String }")
        self.assertIn("Query", names)
        self.assertIn("FooFilter", names)
        # FooFilter must be classified as INPUT_OBJECT (not OBJECT) — we used
        # to do this by name heuristic (`endswith("Filter")`). The proper
        # parser uses the actual `input` keyword.
        types = parse_graphql_schema("type BloomFilter { ok: Boolean } input RealFilter { x: String }")["data"]["__schema"]["types"]
        bloom = next(t for t in types if t["name"] == "BloomFilter")
        real = next(t for t in types if t["name"] == "RealFilter")
        self.assertEqual(bloom["kind"], "OBJECT")
        self.assertEqual(real["kind"], "INPUT_OBJECT")

    def test_docstring_with_embedded_quotes_does_not_break_following_types(self) -> None:
        # The original bug: a docstring with `"..."` inside truncated
        # everything after it. This test wires the same shape as the
        # `texts` field that triggered the issue.
        schema = '''
            type Foo {
                """
                Use `text(key: "...")` to look up a value.
                """
                texts: [String!]
            }
            input Bar { x: String }
        '''
        names = self.names_of(schema)
        self.assertIn("Foo", names)
        self.assertIn("Bar", names)

    def test_multiline_docstring(self) -> None:
        schema = '''
            """
            line one
            line two with "quotes" inside
            """
            type Q { a: Int }
        '''
        types = parse_graphql_schema(schema)["data"]["__schema"]["types"]
        q = next(t for t in types if t["name"] == "Q")
        self.assertIn("line one", q["description"])
        self.assertIn("line two", q["description"])

    def test_default_values_in_input_fields_and_args(self) -> None:
        schema = '''
            input Pagination { first: Int = 100 limit: Int = 50 }
            type Q { items(first: Int = 25, names: [String!] = []): String }
        '''
        names = self.names_of(schema)
        self.assertEqual(names, {"Pagination", "Q", "Boolean", "Float", "ID", "Int", "String"})

    def test_list_and_nonnull_combinations(self) -> None:
        schema = "type T { a: String b: String! c: [String] d: [String!]! }"
        t = next(t for t in parse_graphql_schema(schema)["data"]["__schema"]["types"] if t["name"] == "T")
        kinds = [(f["name"], f["type"]["kind"]) for f in t["fields"]]
        self.assertEqual(kinds, [("a", "SCALAR"), ("b", "NON_NULL"), ("c", "LIST"), ("d", "NON_NULL")])

    def test_enum_values_with_descriptions(self) -> None:
        schema = '''
            enum Order {
                """ascending"""
                ASC
                """descending"""
                DESC
            }
        '''
        order = next(t for t in parse_graphql_schema(schema)["data"]["__schema"]["types"] if t["name"] == "Order")
        self.assertEqual([v["name"] for v in order["enumValues"]], ["ASC", "DESC"])
        self.assertEqual(order["enumValues"][0]["description"], "ascending")

    def test_real_schema_has_critical_types(self) -> None:
        # If schema.graphql is in the same repo as this file, parsing it must
        # produce all the types our handler.zig and clients depend on.
        import os
        here = os.path.dirname(os.path.abspath(__file__))
        schema_path = os.path.join(here, "..", "schema.graphql")
        if not os.path.exists(schema_path):
            self.skipTest("schema.graphql not present in expected path")
        with open(schema_path) as f:
            names = self.names_of(f.read())
        for must_have in ["Query", "Domain", "Event", "Registration",
                          "DomainFilter", "EventFilter", "RegistrationFilter",
                          "OrderDirection"]:
            self.assertIn(must_have, names, f"missing type {must_have}")


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        # Run tests instead of generating output. Used in CI / pre-commit.
        sys.argv = sys.argv[:1]
        unittest.main(module="__main__", verbosity=2)
        return

    if len(sys.argv) != 3:
        print("Usage: generate_introspection.py <input.graphql> <output.json>")
        print("       generate_introspection.py --self-test")
        sys.exit(1)

    with open(sys.argv[1]) as f:
        schema_text = f.read()

    introspection = parse_graphql_schema(schema_text)

    # Defensive write: this sandbox's virtiofs mount can intermittently corrupt large
    # writes (a NUL byte at a 32 KiB block boundary), which would make Zig's strict
    # `@embedFile` JSON parser reject the introspection at startup. Write, read back, and
    # verify it round-trips as valid NUL-free JSON; retry a few times before failing loud.
    payload = json.dumps(introspection, indent=2)
    out_path = sys.argv[2]
    verified = False
    for _ in range(5):
        with open(out_path, "w") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        with open(out_path, "rb") as f:
            written = f.read()
        if b"\x00" not in written:
            try:
                json.loads(written.decode("utf-8"))
                verified = True
                break
            except ValueError:
                pass
    if not verified:
        sys.stderr.write("generate_introspection: output failed NUL/JSON verification after retries\n")
        sys.exit(1)

    print(f"\u2705 Generated introspection: {out_path}")


if __name__ == "__main__":
    main()
