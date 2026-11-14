// The share panel's pages: the first one (what to share, then where it goes),
// 「链接」 and 「文件」. 「图片」 is share_image_page.dart; 「选中消息」 the message
// picker. docs/design/share-redesign.md §4.
//
//   分享
//   (( 这条回复 )  选中消息   整段对话 )
//   (✓ 思考过程) (✓ 工具调用) (✓ 图片)
//   [ card ]
//   ⛨ 2 条消息 · 3 次工具调用 · 密钥已隐藏          调整
//     (链接)    (图片)    (文件)    (文字)

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../share_code/conversation_share.dart' show maxConversationFileBytes;
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/segmented_pill.dart';
import '../common/sheet_navigator.dart';
import '../export/conversation_out.dart';
import '../session/workspace_files.dart' show formatBytes;
import '../share_code/share_code_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../export/export_widgets.dart';
import 'share_panel.dart';
import 'share_picker.dart';

/// The first page: scope, what it includes, the card, then the ways out.
class SharePanelHome extends StatelessWidget {
  const SharePanelHome({super.key});

  void _pick(BuildContext context, SharePanelModel model) {
    final navigator = SheetNavigator.of(context);
    navigator.push(
      (_) => MessagePicker(
        items: model.shareable,
        selected: model.pickStart,
        onDone: (keys) {
          model.pick(keys);
          navigator.pop();
        },
      ),
    );
  }

  void _open(BuildContext context, WidgetBuilder page) {
    final model = SharePanelScope.of(context);
    model.clearError();
    SheetNavigator.of(context).push(page);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final model = SharePanelScope.of(context);
    final conversation = model.conversation != null;
    final ready = model.ready;
    final privacy = model.privacy;
    final top = <Widget>[
      if (conversation && model.scopes.length > 1)
        SegmentedPill<ShareScope>(
          key: const ValueKey('share-scope'),
          segments: [for (final s in model.scopes) PillSegment(s, s.label)],
          selected: model.scope,
          onChanged: (scope) => scope == ShareScope.picked ? _pick(context, model) : model.setScope(scope),
        ),
      if (conversation) ...[
        const SizedBox(height: 12),
        Wrap(
          key: const ValueKey('share-privacy'),
          spacing: 8,
          runSpacing: 8,
          children: [
            ShareToggle(
              label: l10n.viewShareThinking,
              selected: privacy.thinking,
              onSelected: () => model.setPrivacy(privacy.copyWith(thinking: !privacy.thinking)),
            ),
            ShareToggle(
              label: l10n.viewShareIncludeTools,
              selected: privacy.tools,
              onSelected: () => model.setPrivacy(privacy.copyWith(tools: !privacy.tools)),
            ),
            ShareToggle(
              label: l10n.viewShareImages,
              selected: privacy.images,
              onSelected: () => model.setPrivacy(privacy.copyWith(images: !privacy.images)),
            ),
          ],
        ),
      ],
    ];
    final Widget preview = ready ? const SizedBox.shrink() : _Placeholder(empty: model.isEmpty);
    final destinations = ShareActionRow(
      key: const ValueKey('share-destinations'),
      actions: [
        ShareAction(
          key: const ValueKey('share-to-file'),
          icon: AppIcons.shareFile,
          label: l10n.viewShareAsFile,
          onTap: ready ? () => _open(context, (_) => const ShareFilePage()) : null,
        ),
        if (conversation)
          ShareAction(
            key: const ValueKey('share-to-text'),
            icon: AppIcons.shareText,
            label: l10n.viewShareAsText,
            busy: model.work == ShareWork.text,
            onTap: ready ? model.shareText : null,
          ),
      ],
    );
    return SharePageLayout(
      title: l10n.commonShare,
      top: top,
      preview: preview,
      bottom: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ready) _Summary(onAdjust: model.scope == ShareScope.picked ? () => _pick(context, model) : null),
          if (model.error case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                key: const ValueKey('share-status'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).danger),
              ),
            ),
          const SizedBox(height: 12),
          destinations,
        ],
      ),
    );
  }
}

/// While the conversation arrives, or when it has nothing to share.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.empty});

  final bool empty;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return SizedBox(
      height: 240,
      child: Center(
        child: empty
            ? Text(
                context.l10n.viewShareEmpty,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
              )
            : SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  strokeCap: StrokeCap.round,
                  color: colors.textTertiary,
                ),
              ),
      ),
    );
  }
}

/// 「⛨ 2 条消息 · 3 次工具调用 · 密钥已隐藏  调整」: what goes out, in one
/// line; a file's kind and size for a delivered file.
class _Summary extends StatelessWidget {
  const _Summary({this.onAdjust});

  final VoidCallback? onAdjust;

  /// The row's height: the 「调整」 button's, so the row keeps its place when
  /// the button comes and goes.
  static const height = 40.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final model = SharePanelScope.of(context);
    final style = AppType.tabular(theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary));
    final String text;
    final IconData icon;
    if (model.artifact case final a?) {
      icon = AppIcons.shareFile;
      text = [a.artifact.typeLabel, if (a.artifact.bytes case final b?) formatBytes(b)].join(' · ');
    } else {
      final counts = model.counts;
      icon = AppIcons.redacted;
      text = [
        l10n.viewShareMessageCount(counts.messages),
        if (counts.tools > 0) l10n.viewShareToolCount(counts.tools),
        if (counts.images > 0) l10n.viewImageCount(counts.images),
        l10n.viewShareRedacted,
      ].join(' · ');
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: height),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 16,
            child: model.historyLoading
                ? Padding(
                    padding: const EdgeInsets.all(2),
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      strokeCap: StrokeCap.round,
                      color: colors.textTertiary,
                    ),
                  )
                : Icon(icon, size: 16, color: colors.textTertiary),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, key: const ValueKey('share-summary'), style: style),
          ),
          if (onAdjust case final onAdjust?)
            TextButton(
              key: const ValueKey('share-adjust'),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, height),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onAdjust,
              child: Text(l10n.viewShareAdjust),
            ),
        ],
      ),
    );
  }
}

/// 「预览」: the replay the receiver gets (no 「接着聊」).
class _FileTile extends StatelessWidget {
  const _FileTile({required this.name, this.size});

  final String name;
  final String? size;

  @override
  Widget build(BuildContext context) => SheetGroup(
    margin: EdgeInsets.zero,
    children: [
      ListPageRow(
        key: const ValueKey('share-file-row'),
        icon: AppIcons.shareFile,
        title: name,
        titleMaxLines: 2,
        subtitle: size,
      ),
    ],
  );
}

class ShareFilePage extends StatefulWidget {
  const ShareFilePage({super.key});

  @override
  State<ShareFilePage> createState() => _ShareFilePageState();
}

class _ShareFilePageState extends State<ShareFilePage> {
  late final SharePanelModel _model = SharePanelScope.of(context);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _model.conversation != null) unawaited(_model.prepare());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final model = SharePanelScope.of(context);
    final artifact = model.artifact;
    final built = model.built;
    final format = model.format;
    final String name;
    final String? size;
    final String? hint;
    if (artifact != null) {
      name = artifact.artifact.name;
      size = [artifact.artifact.typeLabel, if (artifact.artifact.bytes case final b?) formatBytes(b)].join(' · ');
      hint = null;
    } else {
      name = ConversationOut.fileName(built?.share.title ?? model.chat.title ?? '', format);
      size = built == null ? null : formatBytes(built.of(format).bytes);
      hint = switch (format) {
        ConversationFormat.file => l10n.viewShareFileHint,
        ConversationFormat.page => l10n.viewShareWebHint,
        ConversationFormat.markdown => l10n.viewShareMarkdownHint,
      };
    }
    final top = <Widget>[
      if (artifact == null) ...[
        SegmentedPill<ConversationFormat>(
          key: const ValueKey('share-file-format'),
          segments: [
            PillSegment(ConversationFormat.file, l10n.viewShareChatFile),
            PillSegment(ConversationFormat.page, l10n.viewShareWebPage),
            PillSegment(ConversationFormat.markdown, 'Markdown'),
          ],
          selected: format,
          onChanged: model.work == null ? (f) => model.format = f : null,
        ),
        const SizedBox(height: 16),
      ],
      _FileTile(name: name, size: size),
      if (hint != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
          child: Text(
            hint,
            key: const ValueKey('share-file-hint'),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
          ),
        ),
    ];
    final ready = artifact != null || built != null;
    final idle = ready && !model.fileTooLarge;
    final progress = model.progress;
    final String? error =
        model.error ?? (model.fileTooLarge ? l10n.viewShareTooLarge(maxConversationFileBytes ~/ (1024 * 1024)) : null);
    return SharePageLayout(
      title: l10n.viewShareAsFile,
      top: top,
      bottom: ShareStatusBar(
        error: error,
        status: progress == null || model.work == null ? null : l10n.chatDownloadingPercent((progress * 100).round()),
        child: ShareActionBar(
          saveKey: const ValueKey('share-file-save'),
          shareKey: const ValueKey('share-file-send'),
          saveLabel: l10n.commonSave,
          saved: model.fileSaved,
          busy: switch (model.work) {
            ShareWork.saving => ShareActionBusy.saving,
            ShareWork.sharing => ShareActionBusy.sharing,
            _ => null,
          },
          onSave: idle ? model.saveFile : null,
          onShare: idle ? model.shareFile : null,
        ),
      ),
    );
  }
}
