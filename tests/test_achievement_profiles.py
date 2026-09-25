import json
import tempfile
import unittest
from pathlib import Path

from windows.tapenexus.achievements import AchievementStats, AchievementsManager


class AchievementProfileTests(unittest.TestCase):
    def test_legacy_stats_are_claimed_once_and_accounts_stay_isolated(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "achievements.json"
            legacy = AchievementStats(total_completed=7, display_name="Legacy")
            path.write_text(json.dumps(legacy.to_dict()), encoding="utf-8")

            manager = AchievementsManager(tmp)
            manager.activate_user("user-a")
            self.assertEqual(manager.stats.total_completed, 7)

            manager.stats.total_completed = 8
            manager.save()
            manager.activate_user("user-b")
            self.assertEqual(manager.stats.total_completed, 0)
            self.assertEqual(manager.stats.display_name, "")

            manager.activate_user("user-a")
            self.assertEqual(manager.stats.total_completed, 8)
            self.assertEqual(manager.stats.display_name, "Legacy")

    def test_signed_out_profile_is_empty_and_not_persisted_over_an_account(self):
        with tempfile.TemporaryDirectory() as tmp:
            manager = AchievementsManager(tmp)
            manager.activate_user("user-a")
            manager.stats.total_completed = 4
            manager.save()

            manager.activate_user(None)
            self.assertEqual(manager.stats.total_completed, 0)
            manager.stats.total_completed = 99
            manager.save()

            manager.activate_user("user-a")
            self.assertEqual(manager.stats.total_completed, 4)


if __name__ == "__main__":
    unittest.main()
