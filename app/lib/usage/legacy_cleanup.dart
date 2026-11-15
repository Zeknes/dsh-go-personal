import 'package:shared_preferences/shared_preferences.dart';

Future<void> clearLegacyUsageStats() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().where((key) => key.startsWith('usage_stats_') || key == 'star_prompt')) {
      await prefs.remove(key);
    }
  } catch (_) {
    // Retry on the next launch if preferences are unavailable.
  }
}
