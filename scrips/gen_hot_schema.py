#!/usr/bin/env python3
import json, argparse

parser = argparse.ArgumentParser(description="Generate a hot JSON Schema")
parser.add_argument("--width", type=int, default=100, help="number of properties (parallel blocks)")
parser.add_argument("--depth", type=int, default=10, help="nesting depth of allOf+if/then/else per property")
parser.add_argument("--out", required=True, help="output schema path")
args = parser.parse_args()

def nested_block(name: str, depth: int):
    """
    Build a schema that is an 'allOf' chain of length=depth.
    Each link adds an if/then/else where the THEN branch nests the previous level.
    This keeps refs + conditionals + allOf composed, which stressed OpenAPI.
    """
    # the innermost THEN target is a $ref to a small leaf
    node = {"$ref": "#/$defs/Leaf"}
    for lvl in range(1, depth + 1):
        node = {
            "allOf": [
                { "type": "object" },
                {
                    "if": {
                        "required": ["kind"],
                        "properties": { "kind": { "const": f"{name}_K{lvl}" } }
                    },
                    "then": node,  # nest the previous level here (grows with depth)
                    "else": { "$ref": "#/$defs/Alt" }
                }
            ]
        }
    return node

schema = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "https://example.com/hot_nested",
    "$defs": {
        "Leaf": {
            "type": "object",
            "properties": { "x": { "type": "integer" } },
            "required": ["x"],
            "additionalProperties": False
        },
        "Alt": {
            "type": "object",
            "properties": { "y": { "type": "string" } },
            "additionalProperties": False
        }
    },
    "type": "object",
    "properties": {},
    "additionalProperties": False
}

for i in range(1, args.width + 1):
    pname = f"p{i}"
    schema["properties"][pname] = nested_block(pname, args.depth)

with open(args.out, "w") as f:
    json.dump(schema, f, indent=2)
print(f"Wrote {args.out} (width={args.width}, depth={args.depth})")
