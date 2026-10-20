"""Exercise complete-profile admission and its missing, mixed, and forged controls."""

import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from record_linux_runner import reviewed_profile


class RunnerProfileTest(unittest.TestCase):
    def setUp(self):
        self.first = {"tool_sha256": "a" * 64, "kernel": "kernel-one", "image": "image-one", "memory": True}
        self.second = {**self.first, "kernel": "kernel-two", "image": "image-two"}
        self.configured = {"format": "atlas-linux-runner-profile-set-v1", "profiles": [
            {"format": "atlas-linux-runner-profile-v1", "profile": self.first},
            {"format": "atlas-linux-runner-profile-v1", "profile": self.second},
        ]}

    def test_exact_first_profile(self):
        self.assertEqual(reviewed_profile(self.configured, self.first)["profile"], self.first)

    def test_exact_second_profile(self):
        self.assertEqual(reviewed_profile(self.configured, self.second)["profile"], self.second)

    def test_changed_tool_hash_is_refused(self):
        with self.assertRaises(RuntimeError):
            reviewed_profile(self.configured, {**self.first, "tool_sha256": "b" * 64})

    def test_mixed_image_and_kernel_are_refused(self):
        with self.assertRaises(RuntimeError):
            reviewed_profile(self.configured, {**self.first, "image": self.second["image"]})

    def test_missing_field_is_refused(self):
        changed = dict(self.first)
        del changed["memory"]
        with self.assertRaises(RuntimeError):
            reviewed_profile(self.configured, changed)

    def test_boolean_as_integer_is_refused(self):
        with self.assertRaises(RuntimeError):
            reviewed_profile(self.configured, {**self.first, "memory": 1})

    def test_empty_roster_is_refused(self):
        with self.assertRaises(RuntimeError):
            reviewed_profile({**self.configured, "profiles": []}, self.first)

    def test_duplicate_profile_is_refused(self):
        changed = copy.deepcopy(self.configured)
        changed["profiles"].append(copy.deepcopy(changed["profiles"][0]))
        with self.assertRaises(RuntimeError):
            reviewed_profile(changed, self.first)

    def test_unsupported_format_is_refused(self):
        with self.assertRaises(RuntimeError):
            reviewed_profile({**self.configured, "format": "unknown"}, self.first)


if __name__ == "__main__":
    unittest.main(verbosity=2)
