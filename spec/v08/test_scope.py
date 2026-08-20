from __future__ import annotations

import copy
import json
import re
import unittest

from spec.v08 import scope


class V08ScopeTests(unittest.TestCase):
  def test_generated_scope_closes_wire_compression_surface(self) -> None:
    generated = scope.generate()
    committed = json.loads(scope.OUTPUT.read_text(encoding="utf-8"))

    self.assertEqual(committed, generated)
    self.assertEqual(
      {
        "classified": 16,
        "passed": 16,
        "planned": 0,
        "supported": 16,
      },
      generated["summary"],
    )
    self.assertEqual(
      {
        "configuration_cases": 5,
        "prose_requirements": 11,
      },
      generated["evidence"],
    )
    self.assertEqual(
      {
        "compression": {"passed": 11},
        "uri-options": {"passed": 5},
      },
      generated["suites"],
    )

  def test_every_normative_behavior_has_exact_passing_evidence(self) -> None:
    generated = scope.generate()

    self.assertEqual(
      {
        "compression/OP_COMPRESSED.md::client-options",
        "compression/OP_COMPRESSED.md::framing-and-malformed-messages",
        "compression/OP_COMPRESSED.md::handshake-and-negotiation",
        "compression/OP_COMPRESSED.md::prohibited-commands",
        "compression/OP_COMPRESSED.md::response-decompression",
        "compression/OP_COMPRESSED.md::sharded-round-trip",
        "compression/OP_COMPRESSED.md::snappy-codec",
        "compression/OP_COMPRESSED.md::standalone-round-trips",
        "compression/OP_COMPRESSED.md::unavailable-codec-warnings",
        "compression/OP_COMPRESSED.md::zlib-codec",
        "compression/OP_COMPRESSED.md::zstandard-codec",
      },
      set(generated["prose_requirements"]),
    )

  def test_deferred_or_stale_prose_evidence_fails_closure(self) -> None:
    cases = scope.load_cases()
    requirements = copy.deepcopy(scope.load_requirements())
    activities = scope.load_activities()
    identity = "compression/OP_COMPRESSED.md::prohibited-commands"

    requirements[identity]["status"] = "deferred_unsupported"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, requirements, activities)

    requirements = copy.deepcopy(scope.load_requirements())
    requirements[identity]["runner"] = "spec/unit/future_compression_spec.lua"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, requirements, activities)


if __name__ == "__main__":
  unittest.main()
