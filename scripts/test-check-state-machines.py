#!/usr/bin/env python3
"""Regression tests for scripts/check-state-machines.py.

`python3 scripts/test-check-state-machines.py`; `make check-state-machines`
and .github/workflows/state-machines.yml run it before the check itself.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import pathlib
import tempfile
import textwrap
import unittest

SCRIPT = pathlib.Path(__file__).with_name("check-state-machines.py")
spec = importlib.util.spec_from_file_location("check_state_machines", SCRIPT)
assert spec and spec.loader
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def swift(source: str) -> list[str]:
    return check.swift_machines(textwrap.dedent(source))


def rust(source: str) -> list[str]:
    return check.rust_machines(textwrap.dedent(source))


class SwiftConformers(unittest.TestCase):
    def test_a_wrapped_conformance_list(self) -> None:
        self.assertEqual(swift("struct FooMachine:\n    Equatable,\n    StateMachine {\n}"), ["FooMachine"])

    def test_nested_generic_brackets(self) -> None:
        self.assertEqual(swift("struct Adapter<S: Sequence<Int>>: StateMachine {}"), ["Adapter"])

    def test_attributes_and_qualified_names(self) -> None:
        self.assertEqual(
            swift("final class A: @unchecked Sendable, Waycar.StateMachine {}\nenum B: StateMachine {}"),
            ["A", "B"],
        )

    def test_an_extension(self) -> None:
        self.assertEqual(swift("extension Outer.Baz: StateMachine {}"), ["Baz"])

    def test_a_where_clause_is_not_conformance(self) -> None:
        self.assertEqual(swift("struct Container<T>: Sendable where T: StateMachine {}"), [])
        self.assertEqual(swift("extension Array: Sendable where Element: StateMachine {}"), [])

    def test_comments_and_strings_are_not_code(self) -> None:
        source = '''
            /* outer /* nested */ struct InComment: StateMachine {} */
            // struct InLine: StateMachine {}
            let a = "struct InString: StateMachine {}"
            let b = """
            struct InMultiline: StateMachine {}
            """
            let c = #"struct InRaw: "StateMachine" {}"#
            let d = "\\(value) struct InInterpolation: StateMachine {}"
            struct Real: StateMachine {}
        '''
        self.assertEqual(swift(source), ["Real"])

    def test_string_literals_inside_interpolation(self) -> None:
        source = r'''
            let s = "\(String(repeating: "(", count: 2))"
            struct Real: StateMachine {}
        '''
        self.assertEqual(swift(source), ["Real"])

    def test_comments_inside_interpolation(self) -> None:
        source = r'''
            let s = "\(1 /* " */)"
            let t = "\(f(x) // ")
            )"
            struct Real: StateMachine {}
        '''
        self.assertEqual(swift(source), ["Real"])

    def test_raw_string_interpolation_and_escapes(self) -> None:
        source = r'''
            let t = #"\#(f("(")) struct InRaw: StateMachine {}"#
            let u = "a \" b \\"
            struct Real: StateMachine {}
        '''
        self.assertEqual(swift(source), ["Real"])

    def test_class_members_and_the_protocol_itself(self) -> None:
        source = "protocol StateMachine: Sendable {}\nclass Foo { class func make() {} }\nstruct Bar: Sendable {}"
        self.assertEqual(swift(source), [])


class RustConformers(unittest.TestCase):
    def test_plain_generic_and_qualified_impls(self) -> None:
        source = """
            impl StateMachine for A {}
            impl<T: Into<String>> StateMachine for Adapter<T> {}
            impl crate::state_machine::StateMachine for C {}
            impl Default for D {}
        """
        self.assertEqual(rust(source), ["A", "Adapter", "C"])

    def test_strings_chars_and_comments_are_not_code(self) -> None:
        source = """
            let quote = '"';
            // impl StateMachine for InComment {}
            /* /* */ impl StateMachine for InBlock {} */
            let s = "impl StateMachine for InString {}";
            let r = r#"impl StateMachine for "InRaw" {}"#;
            impl StateMachine for Real {}
        """
        self.assertEqual(rust(source), ["Real"])


class WholeTree(unittest.TestCase):
    def run_check(self, files: dict[str, str]) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            for name, content in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(textwrap.dedent(content), encoding="utf-8")
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()):
                status = check.run(root)
            return status, stderr.getvalue()

    def test_an_indexed_tree_passes(self) -> None:
        status, errors = self.run_check({
            "Sources/A.swift": "struct FooMachine: StateMachine {}\n",
            "docs/design/state-machines.md": """
                ## Index

                ### FooMachine

                - **File:** `Sources/A.swift`

                ## Catalogue

                | A-01 | x | `Sources/A.swift` | implicit | H/H | converted → `FooMachine` | P1 |
            """,
        })
        self.assertEqual((status, errors), (0, ""))

    def test_every_kind_of_drift_is_reported(self) -> None:
        status, errors = self.run_check({
            "Sources/A.swift": "struct FooMachine: StateMachine {}\nstruct Plain {}\n",
            "plugin/rust/h.rs": "impl StateMachine for HookMachine {}\n",
            "docs/design/state-machines.md": """
                ## Index

                ### GoneMachine

                - **File:** `Sources/A.swift`

                ### Plain

                - **File:** `Sources/A.swift`

                ## Catalogue

                | A-01 | x | `Sources/Missing.swift` | implicit | H/H | converted → `NopeMachine` | P1 |
            """,
        })
        self.assertEqual(status, 1)
        for expected in (
            "`FooMachine` conforms to StateMachine but has no",
            "`HookMachine` conforms to StateMachine but has no",
            "`GoneMachine` names Sources/A.swift, which does not declare it",
            "`Plain` does not conform to StateMachine",
            "row A-01 names Sources/Missing.swift, which does not exist",
            "row A-01 is converted to `NopeMachine`",
        ):
            self.assertIn(expected, errors)


if __name__ == "__main__":
    unittest.main()
