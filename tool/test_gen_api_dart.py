"""Unit tests for tool/gen_api_dart.py (no dart needed: formatting is not run)."""
import unittest

import gen_api_dart as gen


class GenApiDartTest(unittest.TestCase):
    def test_types_follow_the_schema(self):
        self.assertEqual(gen.dart_type({"type": "integer"}, "x"), ("int", False))
        self.assertEqual(gen.dart_type({"type": ["string", "null"]}, "x"), ("String", True))
        self.assertEqual(
            gen.dart_type({"type": "array", "items": {"$ref": "#/components/schemas/Spot"}}, "x"),
            ("List<Spot>", False))
        self.assertEqual(gen.dart_type({"type": "object"}, "x"), ("Map<String, Object?>", False))

    def test_unsupported_schemas_fail_loudly(self):
        for schema in ({"type": ["string", "integer"]}, {"$ref": "other.json#/x"},
                       {"type": "array", "items": {"type": ["string", "null"]}},
                       {"type": "object", "properties": {}}):
            with self.subTest(schema=schema), self.assertRaises(gen.GenError):
                gen.dart_type(schema, "x")

    def test_model_reads_writes_and_compares_every_field(self):
        text = gen.model("Row", {
            "type": "object", "required": ["id", "tags"],
            "properties": {"id": {"type": "integer"},
                           "tags": {"type": "array", "items": {"type": "string"}},
                           "note_text": {"type": "string"}},
        })
        self.assertIn("required this.id,", text)
        self.assertIn("this.noteText,", text)  # not required, so nullable
        self.assertIn("final String? noteText;", text)
        self.assertIn("id: (json['id'] as num).toInt(),", text)
        self.assertIn("'note_text': noteText,", text)
        self.assertIn("_equal(other.tags, tags)", text)
        self.assertIn("Object.hashAll([id, _hash(tags), noteText])", text)
        self.assertTrue(gen.helpers([text]))
        self.assertFalse(gen.helpers([text.replace("_equal(", "x(")]))

    def test_operation_has_typed_and_raw_methods(self):
        op = {"summary": "Echo.", "requestBody": {"content": {"application/json": {"schema": {
            "type": "object", "required": ["p_id"],
            "properties": {"p_id": {"type": "integer"}}}}}},
            "responses": {"200": {"content": {"application/json": {
                "schema": {"type": "boolean"}}}}}}
        text = gen.operation("echo_id", op)
        self.assertIn("Future<bool> echoId({required int pId}) async", text)
        self.assertIn(
            "Future<Object?> echoIdRaw({required int pId}) => _call('echo_id', {'p_id': pId});",
            text)

    def test_the_api_v1_document_generates_its_client(self):
        text = gen.generate("api_v1")
        self.assertIn("class ApiV1Client {", text)
        self.assertIn("_client.schema('api_v1')", text)
        self.assertIn("Future<ClientConfig> clientConfig() async", text)
        self.assertNotIn("class ApiError", text)


if __name__ == "__main__":
    unittest.main()
