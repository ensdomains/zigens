#!/usr/bin/env python3
"""
Generate GraphQL introspection JSON from schema.graphql
Simple SDL parser without external dependencies
"""

import json
import re
import sys
from typing import Dict, List, Any

def parse_graphql_schema(schema_text: str) -> Dict[str, Any]:
    """Parse GraphQL SDL and generate introspection response"""

    # Remove comments and normalize whitespace
    lines = []
    for line in schema_text.split('\n'):
        # Remove comments
        if '#' in line:
            line = line[:line.index('#')]
        line = line.strip()
        if line:
            lines.append(line)

    normalized = ' '.join(lines)

    types = []

    # Parse type definitions
    type_pattern = r'type\s+(\w+)\s*\{([^}]+)\}'
    for match in re.finditer(type_pattern, normalized):
        type_name = match.group(1)
        fields_text = match.group(2)

        fields = parse_fields(fields_text, is_input=False)

        types.append({
            "kind": "OBJECT",
            "name": type_name,
            "interfaces": [],
            "fields": fields
        })

    # Parse input types
    input_pattern = r'input\s+(\w+)\s*\{([^}]+)\}'
    for match in re.finditer(input_pattern, normalized):
        type_name = match.group(1)
        fields_text = match.group(2)

        input_fields = parse_fields(fields_text, is_input=True)

        types.append({
            "kind": "INPUT_OBJECT",
            "name": type_name,
            "inputFields": input_fields
        })

    # Parse enum types
    enum_pattern = r'enum\s+(\w+)\s*\{([^}]+)\}'
    for match in re.finditer(enum_pattern, normalized):
        enum_name = match.group(1)
        values_text = match.group(2)

        # Parse enum values
        enum_values = []
        for value in values_text.split():
            if value:
                enum_values.append({
                    "name": value,
                    "description": None,
                    "isDeprecated": False,
                    "deprecationReason": None
                })

        types.append({
            "kind": "ENUM",
            "name": enum_name,
            "enumValues": enum_values
        })

    # Add scalar types
    types.extend([
        {"kind": "SCALAR", "name": "String"},
        {"kind": "SCALAR", "name": "Int"},
        {"kind": "SCALAR", "name": "Boolean"},
    ])

    return {
        "data": {
            "__schema": {
                "queryType": {"name": "Query"},
                "mutationType": None,
                "subscriptionType": None,
                "types": types,
                "directives": []
            }
        }
    }

def parse_fields(fields_text: str, is_input: bool) -> List[Dict[str, Any]]:
    """Parse fields from type definition"""
    fields = []

    # Simple field parsing: fieldName: Type or fieldName(args): Type
    field_pattern = r'(\w+)(?:\(([^)]*)\))?\s*:\s*([^\s,]+)'

    for match in re.finditer(field_pattern, fields_text):
        field_name = match.group(1)
        args_text = match.group(2) or ""
        type_text = match.group(3)

        field_type = parse_type(type_text)

        if is_input:
            fields.append({
                "name": field_name,
                "type": field_type
            })
        else:
            args = []
            if args_text:
                args = parse_arguments(args_text)

            fields.append({
                "name": field_name,
                "args": args,
                "type": field_type
            })

    return fields

def parse_arguments(args_text: str) -> List[Dict[str, Any]]:
    """Parse function arguments"""
    args = []

    # Parse: argName: Type = defaultValue
    arg_pattern = r'(\w+)\s*:\s*([^\s,=]+)(?:\s*=\s*([^\s,]+))?'

    for match in re.finditer(arg_pattern, args_text):
        arg_name = match.group(1)
        type_text = match.group(2)

        args.append({
            "name": arg_name,
            "type": parse_type(type_text)
        })

    return args

def parse_type(type_text: str) -> Dict[str, Any]:
    """Parse GraphQL type notation into introspection format"""
    type_text = type_text.strip()

    # Handle non-null: Type!
    if type_text.endswith('!'):
        inner_type = parse_type(type_text[:-1])
        return {
            "kind": "NON_NULL",
            "ofType": inner_type
        }

    # Handle list: [Type]
    if type_text.startswith('[') and type_text.endswith(']'):
        inner_type = parse_type(type_text[1:-1])
        return {
            "kind": "LIST",
            "ofType": inner_type
        }

    # Determine kind based on type name
    if type_text in ['String', 'Int', 'Boolean', 'Float', 'ID']:
        kind = "SCALAR"
    elif type_text.endswith('Filter') or type_text.endswith('Input'):
        kind = "INPUT_OBJECT"
    elif type_text.endswith('_orderBy') or type_text in ['OrderDirection']:
        kind = "ENUM"
    else:
        kind = "OBJECT"

    return {
        "kind": kind,
        "name": type_text
    }

def main():
    if len(sys.argv) != 3:
        print("Usage: generate_introspection.py <input.graphql> <output.json>")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]

    # Read schema
    with open(input_file, 'r') as f:
        schema_text = f.read()

    # Generate introspection
    introspection = parse_graphql_schema(schema_text)

    # Write output
    with open(output_file, 'w') as f:
        json.dump(introspection, f, indent=2)

    print(f"✅ Generated introspection: {output_file}")

if __name__ == '__main__':
    main()
