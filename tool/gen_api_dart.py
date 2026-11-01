"""Generate the App's Dart client for the unified API (#195 P1).

Reads supabase/api/v1/<schema>.json (OpenAPI 3.1) and writes
lib/api/v1/<schema>.g.dart: plain immutable classes (const constructors,
fromJson/toJson, ==/hashCode, no codegen packages, as lib/models is
written) and a client that calls each function through PostgREST:

    final api = ApiV1Client(supabase, headers: appCheckHeaders);
    final config = await api.clientConfig();     // typed
    final rows = await api.clientConfigRaw();    // the JSON as served

`headers` is called before every request (App Check, #203); `...Raw`
returns the response untouched, for caches that store rows (#202).
A schema without functions writes nothing. The output is run through
`dart format`; CI regenerates it and fails on any difference:

    python3 tool/gen_api_dart.py
    python3 tool/gen_api_dart.py --check
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
API = ROOT / "supabase/api/v1"
OUT = ROOT / "lib/api/v1"
SCHEMAS = ("api_v1", "admin_v1")


class GenError(ValueError):
    pass


def camel(name):
    head, *rest = name.split("_")
    return head + "".join(part[:1].upper() + part[1:] for part in rest)


def pascal(name):
    return "".join(part[:1].upper() + part[1:] for part in re.split(r"[_\W]+", name) if part)


def ref_name(ref):
    if not ref.startswith("#/components/schemas/"):
        raise GenError(f"unsupported $ref {ref}")
    return ref.rsplit("/", 1)[1]


def dart_type(schema, where):
    """The Dart type for a property schema, and whether it may be null."""
    if "$ref" in schema:
        return ref_name(schema["$ref"]), False
    kind = schema.get("type")
    nullable = False
    if isinstance(kind, list):
        nullable = "null" in kind
        kinds = [k for k in kind if k != "null"]
        if len(kinds) != 1:
            raise GenError(f"{where}: one non-null type expected, got {kind}")
        kind = kinds[0]
    base = {"string": "String", "integer": "int", "number": "double", "boolean": "bool"}.get(kind)
    if base:
        return base, nullable
    if kind == "array":
        inner, inner_null = dart_type(schema.get("items", {}), f"{where}[]")
        if inner_null:
            raise GenError(f"{where}: nullable list items are not supported")
        return f"List<{inner}>", nullable
    if kind == "object" and "properties" not in schema:
        return "Map<String, Object?>", nullable
    raise GenError(f"{where}: unsupported schema {json.dumps(schema)[:80]}")


def from_json(expr, kind, nullable):
    """Dart that reads `expr` (an Object?) as `kind`."""
    if nullable:
        return f"{expr} == null ? null : {from_json(expr, kind, False)}"
    if kind == "int":
        return f"({expr} as num).toInt()"
    if kind == "double":
        return f"({expr} as num).toDouble()"
    if kind in ("String", "bool"):
        return f"{expr} as {kind}"
    if kind == "Map<String, Object?>":
        return f"Map<String, Object?>.from({expr} as Map)"
    if kind.startswith("List<"):
        inner = kind[5:-1]
        return f"[for (final e in {expr} as List) {from_json('e', inner, False)}]"
    return f"{kind}.fromJson({expr} as Map<String, Object?>)"


def to_json(expr, kind, nullable):
    if kind.startswith("List<"):
        inner = kind[5:-1]
        item = to_json("e", inner, False)
        body = expr if item == "e" else f"[for (final e in {expr}) {item}]"
        return f"{expr}?.map((e) => {item}).toList()" if nullable and item != "e" else body
    if kind in ("String", "bool", "int", "double", "Map<String, Object?>"):
        return expr
    return f"{expr}?.toJson()" if nullable else f"{expr}.toJson()"


def model(name, schema):
    if schema.get("type") != "object" or "properties" not in schema:
        raise GenError(f"{name}: only object schemas become classes")
    required = set(schema.get("required", []))
    fields = []
    for key, prop in schema["properties"].items():
        kind, nullable = dart_type(prop, f"{name}.{key}")
        nullable = nullable or key not in required
        fields.append((key, camel(key), kind, nullable, prop.get("description")))
    lines = []
    if schema.get("description"):
        lines.append(f"/// {schema['description']}")
    lines.append(f"class {name} {{")
    lines.append(f"  const {name}({{")
    for _, field, _, nullable, _ in fields:
        lines.append(f"    {'' if nullable else 'required '}this.{field},")
    lines.append("  });")
    lines.append("")
    lines.append(f"  factory {name}.fromJson(Map<String, Object?> json) => {name}(")
    for key, field, kind, nullable, _ in fields:
        lines.append(f"        {field}: {from_json(f'json[{key!r}]', kind, nullable)},")
    lines.append("      );")
    for key, field, kind, nullable, description in fields:
        lines.append("")
        if description:
            lines.append(f"  /// {description}")
        lines.append(f"  final {kind}{'?' if nullable else ''} {field};")
    lines.append("")
    lines.append("  Map<String, Object?> toJson() => {")
    for key, field, kind, nullable, _ in fields:
        lines.append(f"        {key!r}: {to_json(field, kind, nullable)},")
    lines.append("      };")
    lines.append("")
    lines.append("  @override")
    lines.append("  bool operator ==(Object other) =>")
    checks = " &&\n      ".join(
        [f"other is {name}"]
        + [f"_equal(other.{f}, {f})" if k.startswith(("List<", "Map<")) else f"other.{f} == {f}"
           for _, f, k, _, _ in fields])
    lines.append(f"      {checks};")
    lines.append("")
    lines.append("  @override")
    hashed = ", ".join(f"_hash({f})" if k.startswith(("List<", "Map<")) else f for _, f, k, _, _ in fields)
    lines.append(f"  int get hashCode => Object.hashAll([{hashed}]);")
    lines.append("}")
    return "\n".join(lines)


def operation(name, op):
    """The typed and raw client methods for one RPC."""
    method = camel(name)
    params = []
    body = op.get("requestBody")
    if body:
        props = body["content"]["application/json"]["schema"]
        required = set(props.get("required", []))
        for key, prop in props.get("properties", {}).items():
            kind, nullable = dart_type(prop, f"{name}({key})")
            params.append((key, camel(key), kind, nullable, key not in required))
    response = op["responses"]["200"]["content"]["application/json"]["schema"]
    kind, nullable = dart_type(response, f"{name} response")
    returns = kind + ("?" if nullable else "")
    sig = ""
    if params:
        sig = "{" + ", ".join(
            f"{'' if optional else 'required '}{k}{'?' if n or optional else ''} {f}"
            for _, f, k, n, optional in params) + "}"
    call_args = ", ".join(f"{f}: {f}" for _, f, _, _, _ in params)
    # An optional parameter left out is left out of the body too, so the SQL
    # default applies (Codex review, PR #233); a required one is always sent.
    def entry(key, f, k, n, optional):
        if not optional:
            return f"{key!r}: {to_json(f, k, n)}"
        value = to_json(f, k, False)
        return f"{key!r}: ?{f}" if value == f else f"if ({f} != null) {key!r}: {value}"

    body_map = ", ".join(entry(*param) for param in params)
    doc = op.get("summary", "")
    # The raw answer is awaited once and then converted: converting the
    # awaited call itself would repeat the RPC for a nullable type.
    return f"""
  /// {doc}
  Future<{returns}> {method}({sig}) async {{
    final raw = await {method}Raw({call_args});
    return {from_json('raw', kind, nullable)};
  }}

  /// [{method}] as served, for callers that keep the JSON (#202).
  Future<Object?> {method}Raw({sig}) => _call({name!r}, {{{body_map}}});"""


HELPERS = """
bool _equal(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_equal(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_equal(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}

int _hash(Object? value) => switch (value) {
      List() => Object.hashAll(value.map(_hash)),
      Map() => Object.hashAllUnordered(
          value.entries.map((e) => Object.hash(e.key, _hash(e.value))),
        ),
      _ => value.hashCode,
    };
"""


def helpers(models):
    """_equal/_hash, only when a model compares lists or maps (unused code fails analyze)."""
    return HELPERS if any("_equal(" in m for m in models) else ""


def generate(schema):
    doc = json.loads((API / f"{schema}.json").read_text())
    if not doc["paths"]:
        return None
    prefix = pascal(schema)
    client = f"{prefix}Client"
    error = f"{prefix}Exception"
    models = [model(name, s) for name, s in doc["components"]["schemas"].items() if name != "ApiError"]
    ops = []
    for path, item in doc["paths"].items():
        name = path.removeprefix("/rpc/")
        ops.append(operation(name, item["post"]))
    title = doc["info"]["title"]
    return f"""// GENERATED by tool/gen_api_dart.py from supabase/api/v1/{schema}.json.
// Do not edit; change the document and regenerate.
//
// {title}

import 'package:supabase_flutter/supabase_flutter.dart';

/// An API failure (#195 §2.4): [code] is the SQLSTATE (PTxyz for the
/// API's own errors, HTTP xyz), [message] the stable error code to choose
/// wording by, e.g. `auth.aal2_required`.
class {error} implements Exception {{
  const {error}({{required this.code, required this.message, this.details}});

  final String? code;
  final String message;
  final Object? details;

  @override
  String toString() => '{error}($code, $message)';
}}

/// Calls `{schema}` through PostgREST (Content-Profile: {schema}).
class {client} {{
  const {client}(this._client, {{this.headers}});

  final SupabaseClient _client;

  /// Extra headers for every call, e.g. App Check (#203); asked each time.
  final Future<Map<String, String>> Function()? headers;

  Future<Object?> _call(String name, Map<String, Object?> params) async {{
    var request = _client.schema({schema!r}).rpc<Object?>(name, params: params);
    for (final header in (await headers?.call() ?? const {{}}).entries) {{
      request = request.setHeader(header.key, header.value);
    }}
    try {{
      return await request;
    }} on PostgrestException catch (e) {{
      throw {error}(code: e.code, message: e.message, details: e.details);
    }}
  }}
{''.join(ops)}
}}

{chr(10).join(chr(10).join([m, '']) for m in models)}{helpers(models)}"""


def dart_format(paths):
    dart = shutil.which("dart")
    if not dart:
        raise GenError("dart is not on PATH; the output must be dart-formatted")
    subprocess.run([dart, "format", "--output=write", *map(str, paths)], check=True,
                   stdout=subprocess.DEVNULL)


def build(out_dir):
    written = []
    for schema in SCHEMAS:
        target = out_dir / f"{schema}.g.dart"
        text = generate(schema)
        if text is None:
            target.unlink(missing_ok=True)
            continue
        out_dir.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        written.append(target)
    if written:
        dart_format(written)
    return written


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail if lib/api/v1 differs from the documents")
    args = parser.parse_args(argv)
    try:
        if not args.check:
            for path in build(OUT):
                print(f"wrote {path.relative_to(ROOT)}")
            return 0
        with tempfile.TemporaryDirectory() as tmp:
            fresh = {p.name: p.read_text() for p in build(Path(tmp))}
        current = {p.name: p.read_text() for p in OUT.glob("*.g.dart")} if OUT.exists() else {}
        if fresh != current:
            print("gen_api_dart: lib/api/v1 differs from supabase/api/v1; run tool/gen_api_dart.py",
                  file=sys.stderr)
            return 1
        return 0
    except GenError as error:
        print(f"gen_api_dart: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
