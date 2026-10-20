import importlib.util
import pathlib
import unittest

SPEC = importlib.util.spec_from_file_location(
    "check_edge_cases", pathlib.Path(__file__).resolve().parent.parent / "scripts/check_edge_cases.py")
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

MAKEFILE = "test-mic:\n\ttests/integration/mic_recovery.sh\n"
SPECS = 'it("restarts a standby", function() end)'
PYTHON = "    def test_cuts_echo(self):\n"
SWIFT = 'test("track clock fills a gap") {'


class MissingTests(unittest.TestCase):
    def test_existing_references_pass(self):
        doc = ('| a | b | `make test-mic`, `spec "restarts a standby"` |\n'
               '| c | d | `python test_cuts_echo`, `swift "track clock fills a gap"` |')
        self.assertEqual([], check.missing(doc, MAKEFILE, SPECS, PYTHON, SWIFT))

    def test_renamed_or_removed_tests_are_listed(self):
        doc = ('`make test-gone` `spec "restarts a standby at once"` `python test_cuts`'
               ' `swift "track clock"` `spec "restarts a standby"`')
        self.assertEqual(['make test-gone', 'spec "restarts a standby at once"', 'python test_cuts',
                          'swift "track clock"'], check.missing(doc, MAKEFILE, SPECS, PYTHON, SWIFT))

    def test_no_test_rows_are_not_references(self):
        self.assertEqual([], check.missing("| a | b | No test |", MAKEFILE, SPECS, PYTHON, SWIFT))

    def test_the_real_list_names_only_existing_tests(self):
        self.assertEqual(0, check.main())


if __name__ == "__main__":
    unittest.main()
