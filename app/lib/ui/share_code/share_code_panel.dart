import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../share_code/share_codec.dart';
import '../../share_code/share_models.dart';
import 'share_out.dart';

class ShareCodePanel extends ConsumerStatefulWidget {
  const ShareCodePanel({super.key, required this.payload});

  final SharePayload payload;

  @override
  ConsumerState<ShareCodePanel> createState() => _ShareCodePanelState();
}

class _ShareCodePanelState extends ConsumerState<ShareCodePanel> {
  bool busy = false;
  String? error;

  Future<void> export({required bool share}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final out = ref.read(shareOutProvider);
      final payload = widget.payload;
      final name = out.fileName(
        profile: payload is ProfileShare,
        name: payload is PluginShare ? payload.plugin.name : null,
      );
      final content = encodeShareFile(payload);
      if (share) {
        await out.shareFile(await out.write(name, content));
      } else {
        await out.save(name, content);
      }
    } catch (_) {
      error = appL10n.commonSaveFailed;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (error != null) Text(error!),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            key: const ValueKey('share-code-save'),
            onPressed: busy ? null : () => export(share: false),
            child: Text(context.l10n.commonSave),
          ),
          FilledButton(
            key: const ValueKey('share-code-share'),
            onPressed: busy ? null : () => export(share: true),
            child: Text(context.l10n.commonShare),
          ),
        ],
      ),
    ],
  );
}
