// Behaviour and geometry of the share-code sheets.

import 'dart:io';

import 'package:dsh_app/share_code/profile_export.dart';
import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/share_code/share_net.dart';
import 'package:dsh_app/ui/common/app_sheet.dart' show SheetDragHandle;
import 'package:dsh_app/ui/share_code/import_sheet.dart';
import 'package:dsh_app/ui/share_code/plugin_share_sheet.dart';
import 'package:dsh_app/ui/share_code/profile_share_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'support/fake_engine.dart';
import 'support/sheet_support.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _pump(WidgetTester tester, void Function(BuildContext) open, List<dynamic> overrides) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: SheetHost(open: open),
      brightness: Brightness.light,
      overrides: overrides.cast(),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
}

/// A profile too large for a link: it goes out as a file, or a Gist link.
ProfileShare _bigProfile() => ProfileShare(
  skills: [
    for (var i = 0; i < 3; i++)
      SharedSkill(
        name: 'skill-$i',
        files: {
          'SKILL.md': [for (var j = 0; j < 200; j++) '第 $j 行 $i-$j ${j * 7919 % 1000}'].join('\n'),
        },
      ),
  ],
);

void main() {
  late Directory cache;
  setUp(() => cache = Directory.systemTemp.createTempSync('share-sheets-'));
  tearDown(() => cache.deleteSync(recursive: true));

  testWidgets('plugin export writes a valid local file and offers system sharing', (tester) async {
    final out = RecordingShareOut(cache);
    await _pump(
      tester,
      (c) => showSharePluginSheet(c, plugin: notesPlugin),
      shareOverrides(net: sampleNet(), out: out),
    );
    expect(find.byKey(const ValueKey('share-code-copy')), findsNothing);
    expect(find.byKey(const ValueKey('share-code-qr')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('share-code-save')));
    await _settle(tester);
    final payload = decodeShareCode(readShareEnvelope(File(out.saved.single).readAsStringSync()).code) as PluginShare;
    expect(payload.plugin.spec, '@acme/dsh-notes@1.4.2');
    await tester.tap(find.byKey(const ValueKey('share-code-share')));
    await _settle(tester);
    final shared =
        decodeShareCode(readShareEnvelope(File(out.sharedFiles.single).readAsStringSync()).code) as PluginShare;
    expect(shared.plugin.name, notesPlugin.name);
  });

  testWidgets('profile selection exports only selected settings to a local file', (tester) async {
    final fs = await tester.runAsync(() async => sampleGuest());
    addTearDown(() => fs!.root.parent.deleteSync(recursive: true));
    final source = (await tester.runAsync(
      () => loadProfileExport(DshClient.withCarrier(exportEngine()), hostLabel: '本机', isLocal: true, fs: fs),
    ))!;
    final out = RecordingShareOut(cache);
    await _pump(tester, showShareProfileSheet, shareOverrides(net: sampleNet(), out: out, export: source));
    await tester.tap(find.byKey(const ValueKey('share-item-settings:subagent')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('share-profile-next')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('share-code-save')));
    await _settle(tester);
    final share = decodeShareCode(readShareEnvelope(File(out.saved.single).readAsStringSync()).code) as ProfileShare;
    expect(share.settings.keys, isNot(contains('subagent')));
    expect(share.plugins.map((p) => p.name), contains('@acme/dsh-notes'));
  });

  testWidgets('large profile uses local system share without online upload', (tester) async {
    final net = sampleNet();
    final out = RecordingShareOut(cache);
    await _pump(tester, (c) => showProfileSharePreview(c, _bigProfile()), shareOverrides(net: net, out: out));
    await tester.tap(find.byKey(const ValueKey('share-code-share')));
    await _settle(tester);
    final share =
        decodeShareCode(readShareEnvelope(File(out.sharedFiles.single).readAsStringSync()).code) as ProfileShare;
    expect(share.skills, hasLength(3));
    expect(net.created, isEmpty);
    expect(find.byKey(const ValueKey('share-code-gist')), findsNothing);
  });

  testWidgets('local export sheet may be dismissed without exporting', (tester) async {
    final out = RecordingShareOut(cache);
    await _pump(tester, (c) => showProfileSharePreview(c, _bigProfile()), shareOverrides(net: sampleNet(), out: out));
    await tester.fling(find.byType(SheetDragHandle), const Offset(0, 300), 1500);
    await _settle(tester);
    expect(find.byType(ProfileSharePreview), findsNothing);
    expect(out.saved, isEmpty);
    expect(out.sharedFiles, isEmpty);
  });

  testWidgets('安装插件: a changed package can not be installed', (tester) async {
    final engine = FakeEngine();
    final net = FakeShareNet()..npm['@acme/dsh-notes@1.4.2'] = const NpmFacts(integrity: 'sha512-OTHER');
    await _pump(
      tester,
      (c) => showShareImportSheet(c, const PluginShare(notesPlugin)),
      shareOverrides(net: net, targets: [localTarget(DshClient.withCarrier(engine))]),
    );
    expect(find.text('校验不一致'), findsOneWidget);
    expect(find.text('与分享时的版本不一致'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byKey(const ValueKey('share-import-primary')));
    expect(button.onPressed, isNull);
  });

  testWidgets('导入配置: switches choose what runs; another engine replans', (tester) async {
    final local = FakeEngine()
      ..addSettings('subagent', base: {'maxDepth': 1})
      ..addBundle('@acme/dsh-notes', version: '1.4.2', source: '@acme/dsh-notes@1.4.2');
    final remote = FakeEngine()..addSettings('subagent', base: {'maxDepth': 1});
    const profile = ProfileShare(
      settings: {
        'subagent': {'maxDepth': 3},
      },
      plugins: [notesPlugin],
      skills: [
        SharedSkill(name: 'weekly', files: {'SKILL.md': 'x'}),
      ],
    );
    final fs = await tester.runAsync(() async => tempGuest());
    addTearDown(() => fs!.root.parent.deleteSync(recursive: true));
    await _pump(
      tester,
      (c) => showShareImportSheet(c, profile),
      shareOverrides(
        net: sampleNet(),
        targets: [localTarget(DshClient.withCarrier(local)), remoteTarget(DshClient.withCarrier(remote))],
        fs: fs,
      ),
    );
    // Same version already there: shown, nothing to do.
    expect(find.textContaining('无需改动'), findsOneWidget);
    expect(find.text('导入 1 项'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('share-change-skill:weekly')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('share-change-skill:weekly')));
    await tester.pump();
    expect(find.text('导入 2 项'), findsOneWidget);

    await tester.ensureVisible(find.text('书房的 Mac · SSH'));
    await tester.pump();
    await tester.tap(find.text('书房的 Mac · SSH'));
    await _settle(tester);
    expect(find.text('只能导入到本机'), findsOneWidget);
    expect(find.text('导入 2 项'), findsOneWidget, reason: 'install + setting on the Mac');

    await tester.tap(find.byKey(const ValueKey('share-import-primary')));
    await _settle(tester);
    expect(remote.argsOf('pluginManager/installBundle').single['spec'], '@acme/dsh-notes@1.4.2');
    expect(remote.settings['subagent']!['user'], {'maxDepth': 3});
    expect(local.argsOf('pluginManager/installBundle'), isEmpty);
    expect(find.text('已导入 2 项'), findsOneWidget);
  });

  testWidgets('geometry: the done buttons are equal halves, 12 apart, on the gutters', (tester) async {
    final engine = FakeEngine()..restartRequired = true;
    const profile = ProfileShare(plugins: [notesPlugin]);
    await _pump(
      tester,
      (c) => showShareImportSheet(c, profile),
      shareOverrides(net: sampleNet(), targets: [localTarget(DshClient.withCarrier(engine))]),
    );
    await tester.tap(find.byKey(const ValueKey('share-import-primary')));
    await _settle(tester);
    final done = tester.getRect(find.byKey(const ValueKey('share-import-done')));
    final restart = tester.getRect(find.byKey(const ValueKey('share-import-restart')));
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(done.width, moreOrLessEquals(restart.width, epsilon: 0.01));
    expect(done.height, restart.height);
    expect(done.top, restart.top);
    expect(restart.left - done.right, moreOrLessEquals(12, epsilon: 0.01));
    expect(done.left, moreOrLessEquals(width - restart.right, epsilon: 0.01));
    expect(done.left, moreOrLessEquals(20, epsilon: 0.01));
  });
}
