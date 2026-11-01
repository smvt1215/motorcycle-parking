"""The API documents (supabase/api/v1/*.json) and the SQL agree (#195 P1).

Every function a migration creates in api_v1 or admin_v1 has exactly one
operation, `POST /rpc/<name>` with operationId `<schema>_<name>`, and every
operation names a function that exists. The schema is chosen by the
Content-Profile header, named once per document as `x-content-profile`: the
generated clients' base adds it, so operations do not take it. The documents are OpenAPI 3.1 and only reference what they define.
"""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
MIGRATIONS = ROOT / "supabase/migrations"
API = ROOT / "supabase/api/v1"
SCHEMAS = ("api_v1", "admin_v1")

CREATE = re.compile(r"^create (?:or replace )?function (api_v1|admin_v1)\.(\w+)\(", re.M | re.I)
DROP = re.compile(r"^drop function (?:if exists )?(api_v1|admin_v1)\.(\w+)\b", re.M | re.I)


def sql_functions():
    """Functions the migrations leave in each API schema, in apply order."""
    found = {schema: set() for schema in SCHEMAS}
    for migration in sorted(MIGRATIONS.glob("*.sql")):
        text = migration.read_text()
        events = [(m.start(), "create", m.group(1), m.group(2)) for m in CREATE.finditer(text)]
        events += [(m.start(), "drop", m.group(1), m.group(2)) for m in DROP.finditer(text)]
        for _, kind, schema, name in sorted(events):
            (found[schema].add if kind == "create" else found[schema].discard)(name)
    return found


def document(schema):
    return json.loads((API / f"{schema}.json").read_text())


def refs(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref":
                yield value
            else:
                yield from refs(value)
    elif isinstance(node, list):
        for value in node:
            yield from refs(value)


class ApiSchemaTest(unittest.TestCase):
    def test_documents_are_openapi_31(self):
        for schema in SCHEMAS:
            with self.subTest(schema=schema):
                doc = document(schema)
                self.assertEqual(doc["openapi"], "3.1.0")
                self.assertEqual(doc["x-content-profile"], schema)

    def test_every_sql_function_has_one_operation_and_back(self):
        functions = sql_functions()
        self.assertIn("client_config", functions["api_v1"])
        for schema in SCHEMAS:
            with self.subTest(schema=schema):
                paths = document(schema)["paths"]
                documented = {path.removeprefix("/rpc/") for path in paths}
                self.assertTrue(all(path.startswith("/rpc/") for path in paths), paths)
                self.assertEqual(documented, functions[schema],
                                 "document every API function, and only those")

    def test_operations_follow_the_conventions(self):
        for schema in SCHEMAS:
            doc = document(schema)
            for path, item in doc["paths"].items():
                name = path.removeprefix("/rpc/")
                with self.subTest(schema=schema, function=name):
                    self.assertEqual(set(item), {"post"}, "PostgREST RPCs are POST")
                    op = item["post"]
                    self.assertEqual(op["operationId"], f"{schema}_{name}")
                    self.assertNotIn("Content-Profile",
                                     [p.get("name") for p in op.get("parameters", [])],
                                     "the client base sends Content-Profile")
                    self.assertIn("200", op["responses"])
                    self.assertEqual(op["responses"]["default"], {"$ref": "#/components/responses/Error"})

    def test_references_resolve(self):
        for schema in SCHEMAS:
            doc = document(schema)
            for ref in refs(doc):
                with self.subTest(schema=schema, ref=ref):
                    self.assertTrue(ref.startswith("#/"), "only local references")
                    node = doc
                    for part in ref[2:].split("/"):
                        self.assertIn(part, node)
                        node = node[part]


if __name__ == "__main__":
    unittest.main()
