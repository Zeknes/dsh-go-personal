#!/usr/bin/env python3
"""Check the runtime recipe enables the goal default only through its web overlay."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('rtbuild', Path(__file__).resolve().parents[1] / 'lib/rtbuild.py')
rtbuild = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rtbuild)

class GoalDefault(unittest.TestCase):
    def test_web_overlay_sets_unlimited_default(self):
        for with_pnpm, with_bridge in ((True, False), (False, True), (True, True)):
            with self.subTest(with_pnpm=with_pnpm, with_bridge=with_bridge):
                overlay = rtbuild.overlay_entries({}, with_pnpm=with_pnpm, with_bridge=with_bridge)['etc/dsh-app/dsh-web.patch.yml'].read().decode()
                self.assertIn('- id: goal\n  config:\n    defaultMaxGoalRounds: unlimited\n', overlay)

if __name__ == '__main__':
    unittest.main()
