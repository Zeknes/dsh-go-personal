import 'package:dsh_app/usage/legacy_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('removes old anonymous reporting state without touching local data', () async {
    SharedPreferences.setMockInitialValues({
      'usage_stats_enabled': true,
      'usage_stats_iid': 'old-id',
      'usage_stats_days': 'old-ledger',
      'usage_stats_failed_at': 1,
      'star_prompt': 'old-reminder',
      'local_token_count': 42,
    });
    await clearLegacyUsageStats();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((key) => key.startsWith('usage_stats_')), isEmpty);
    expect(prefs.containsKey('star_prompt'), isFalse);
    expect(prefs.getInt('local_token_count'), 42);
    await clearLegacyUsageStats();
  });
}
