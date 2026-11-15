import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../update/update_config.dart';

final starProjectPage = Uri.https('github.com', '/$updateRepo');

final starLinkOpenerProvider = Provider<Future<bool> Function(Uri)>(
  (ref) => (uri) => launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false),
);

Future<void> openStarProject(ProviderContainer container, ScaffoldMessengerState? messenger) async {
  final page = starProjectPage;
  if (await container.read(starLinkOpenerProvider)(page)) return;
  try {
    await Clipboard.setData(ClipboardData(text: page.toString()));
  } catch (_) {}
  messenger?.showSnackBar(SnackBar(content: Text(appL10n.shellBrowserUrlCopied)));
}
