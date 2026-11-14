import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../common/app_sheet.dart';
import '../common/pressable.dart';
import '../common/scroll_edge_fade.dart';
import '../shell/adaptive/adaptive_layout.dart' show WindowClass;
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// A share page's frame: the title (no close key: the sheet drags down), then
/// [top] and [preview] scrolling as one, and [bottom] pinned under them. On a
/// phone on its side the preview takes the left and the rest a column on the
/// right.
class SharePageLayout extends StatelessWidget {
  const SharePageLayout({super.key, required this.title, this.top = const [], this.preview, required this.bottom});

  final String title;
  final List<Widget> top;
  final Widget? preview;
  final Widget bottom;

  @override
  Widget build(BuildContext context) {
    final header = SheetHeader(title);
    if (MediaQuery.sizeOf(context).height < WindowClass.compactHeight && preview != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ScrollEdgeFade(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 16),
                      child: preview,
                    ),
                  ),
                ),
                SizedBox(
                  width: 320.0,
                  child: SafeArea(
                    top: false,
                    left: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 4, kSheetGutter, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // The options scroll; the actions rest at the bottom, as upright.
                          Expanded(
                            child: ScrollEdgeFade(
                              child: SingleChildScrollView(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: top),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          bottom,
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(
          child: ScrollEdgeFade(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...top,
                  if (preview case final preview?) ...[if (top.isNotEmpty) const SizedBox(height: 16), preview],
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(padding: const EdgeInsets.fromLTRB(kSheetGutter, 8, kSheetGutter, 12), child: bottom),
        ),
      ],
    );
  }
}

/// [child] with a one-line [error] above it, when there is one.
class ShareStatusBar extends StatelessWidget {
  const ShareStatusBar({super.key, required this.child, this.error, this.status});

  final Widget child;
  final String? error;

  /// A quiet line when there is no [error] (a size, a link).
  final String? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final text = error ?? status;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (text != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              text,
              key: const ValueKey('share-status'),
              textAlign: TextAlign.center,
              style: AppType.tabular(
                theme.textTheme.bodySmall!.copyWith(color: error != null ? colors.danger : colors.textTertiary),
              ),
            ),
          ),
        child,
      ],
    );
  }
}

/// An on / off capsule: ink check and label when on, a quiet label when off.
/// 12 of air at both ends; at least 32 tall, taller with large text.
class ShareToggle extends StatelessWidget {
  const ShareToggle({super.key, required this.label, required this.selected, required this.onSelected});

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  static const height = 32.0;
  static const padding = 12.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      onTap: onSelected,
      excludeSemantics: true,
      child: Pressable(
        onTap: onSelected,
        child: Container(
          key: ValueKey('share-toggle-$label'),
          constraints: const BoxConstraints(minHeight: height),
          padding: const EdgeInsets.symmetric(horizontal: padding, vertical: 6),
          decoration: ShapeDecoration(
            color: theme.colorScheme.onSurface.withValues(alpha: selected ? 0.10 : 0.04),
            shape: const StadiumBorder(),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(
                  AppIcons.selected,
                  key: ValueKey('share-toggle-check-$label'),
                  size: 16,
                  color: theme.colorScheme.onSurface,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? theme.colorScheme.onSurface : colors.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The card at the page's width (the export keeps the card's own size), in a
/// (「保存图片」); a label too wide shrinks rather than being cut.
enum ShareActionBusy { saving, sharing }

class ShareActionBar extends StatelessWidget {
  const ShareActionBar({
    super.key,
    required this.onSave,
    required this.onShare,
    this.busy,
    this.saved = false,
    this.saveLabel,
    this.saveKey = const ValueKey('share-save'),
    this.shareKey = const ValueKey('share-send'),
  });

  /// Null disables 「保存」.
  final VoidCallback? onSave;

  /// Null disables 「分享」.
  final VoidCallback? onShare;
  final ShareActionBusy? busy;

  /// Just saved: 「已保存」 with a check for a moment.
  final bool saved;
  final String? saveLabel;
  final Key saveKey;
  final Key shareKey;

  static const height = 48.0;
  static const gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    Widget icon(IconData data, bool working, Color color) => SizedBox.square(
      dimension: 18,
      child: working
          ? Padding(
              padding: const EdgeInsets.all(1),
              child: CircularProgressIndicator(strokeWidth: 2, strokeCap: StrokeCap.round, color: color),
            )
          : Icon(data, size: 18),
    );
    Widget label(String text) => FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1, softWrap: false));
    final idle = busy == null;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            key: saveKey,
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(height)),
            onPressed: idle ? onSave : null,
            icon: icon(saved ? AppIcons.done : AppIcons.save, busy == ShareActionBusy.saving, scheme.onSurfaceVariant),
            label: label(saved ? l10n.commonSaved : saveLabel ?? l10n.viewShareSaveImage),
          ),
        ),
        const SizedBox(width: gap),
        Expanded(
          child: FilledButton.icon(
            key: shareKey,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(height)),
            onPressed: idle ? onShare : null,
            icon: icon(AppIcons.share, busy == ShareActionBusy.sharing, scheme.onPrimary),
            label: label(l10n.commonShare),
          ),
        ),
      ],
    );
  }
}
