import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/share_code/conversation_share.dart';
import 'package:dsh_app/share_code/share_code_state.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/share_code/import_sheet.dart';
import 'package:dsh_app/ui/share_code/share_code_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

Future<BuildContext> _pump(WidgetTester tester, {List<Override> overrides = const []}) async {
  usePhoneView(tester);
  late BuildContext opener;
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) {
          opener = context;
          return const Scaffold(body: Text('Home'));
        },
      ),
      overrides: [
        settingsProvider.overrideWith(() => TestSettings()),
        importTargetsProvider.overrideWithValue(const []),
        ...overrides,
      ],
    ),
  );
  return opener;
}

Future<void> _until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 250 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(finder, findsOneWidget);
}

Future<File> _file(WidgetTester tester, List<int> bytes) async {
  final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('share-decode-')))!;
  addTearDown(() => dir.deleteSync(recursive: true));
  return File('${dir.path}/share.dshgo')..writeAsBytesSync(bytes);
}

void main() {
  tearDown(() => AppLocale.use(AppLocale.zhCN));
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGPwTt/yHxkzkC4AAAPnJlH/osXzAAAAAElFTkSuQmCC',
  );
  final asset = ConversationAsset.of(png, mediaType: 'image/png');
  final share = ConversationShare(
    title: '',
    start: DateTime.utc(2026, 11, 11),
    entries: [
      UserEntry(
        t: 0,
        text: '你好 👋',
        images: [
          ImageRef(id: asset.id),
          const ImageRef(id: 'AAAAAAAAAAAA'),
        ],
      ),
    ],
  );
  final envelope = jsonDecode(encodeConversationFile(share, [asset])) as Map<String, dynamic>;
  (envelope['assets'] as Map)['AAAAAAAAAAAA'] = asset.toJson(); // Wrong hash: must still be dropped.
  final bytes = utf8.encode(jsonEncode(envelope));

  testWidgets('conversation export file does not open a replay', (tester) async {
    final opener = await _pump(tester);
    final file = await _file(tester, bytes);
    await tester.runAsync(() async => openShareFile(opener, file));
    await tester.pump();
    expect(find.byType(ShareImportSheet), findsNothing);
  });

  testWidgets('a non-UTF8 file retains the file-read error', (tester) async {
    final opener = await _pump(tester);
    unawaited(openShareFile(opener, await _file(tester, [0xff, 0xfe, 0x00])));
    await _until(tester, find.text(appL10n.pluginsShareFileReadFailed));
  });

  for (final payload in <SharePayload>[
    const PluginShare(SharedPlugin(name: 'test-bundle', source: PluginSourceKind.official)),
    const ProfileShare(
      name: 'Synthetic profile',
      settings: {
        'ui-chat': {'value': 1},
      },
    ),
  ]) {
    testWidgets('${payload.kind.name} still reaches its confirm sheet without an install', (tester) async {
      final opener = await _pump(tester);
      unawaited(openShareLink(opener, ShareLink.inline(payload.kind, encodeShareCode(payload))));
      await _until(tester, find.byType(ShareImportSheet));
      expect(tester.widget<ShareImportSheet>(find.byType(ShareImportSheet)).payload.toJson(), payload.toJson());
    });
  }

  testWidgets('a file beyond the existing size cap is refused', (tester) async {
    final opener = await _pump(tester);
    unawaited(openShareFile(opener, await _file(tester, Uint8List(maxConversationFileBytes * 2 + 1))));
    await _until(tester, find.text(appL10n.pluginsShareDamaged));
  });
}
