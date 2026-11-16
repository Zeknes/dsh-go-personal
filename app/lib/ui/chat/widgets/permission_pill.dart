// The permission chip above the composer (docs/design/settings-ia.md §4.4):
// the conversation's preset — 「⚠ 自动审查 ›」 in the warning tone when it is
// looser than 工作区内修改, a quiet 「仅可查看 ›」/「工作区内修改 ›」 otherwise —
// and a tap opens its permissions. 完全权限 shows no chip at all: it is this
// app's ordinary setting, and 设置 › 权限 still switches it. Grown out of
// [AutoApprovePill], which still says 「自动允许中 ×」 while this client allows
// everything itself. While a reply generates, either one sits right of the
// activity strip ([StripRiskChip]).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../features/feature_format.dart' show permissionName;
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';

export 'auto_approve_pill.dart' show AutoApprovePill;

/// The pills' shared geometry; `test/chat/permission_pill_test.dart` measures it.
abstract final class PermissionPillMetrics {
  /// As high as the plugin capsules they lead (`CapsuleMetrics.height`).
  static const height = 34.0;

  /// Pill edge → the end icons, the same on both sides.
  static const inset = 10.0;
  static const icon = 16.0;
}

/// The conversation's permission: 34 high, an icon at each end, equal insets.
/// [compact] (beside the generation mode capsule) is the 34 round glyph alone.
class PermissionPill extends StatelessWidget {
  const PermissionPill({
    super.key,
    required this.preset,
    required this.onTap,
    this.compact = false,
    this.warn = false,
  });

  /// `read-only`, `workspace-write`, `auto` or `custom`; never
  /// `danger-full-access`, which shows no chip.
  final String preset;
  final VoidCallback onTap;
  final bool compact;

  /// 自动审查 (`auto`) is looser than 工作区内修改: the chip warns in the
  /// warning tone; the other presets are restrictive and stay quiet.
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final scheme = theme.colorScheme;
    final fg = warn ? dsh.onWarningContainer : scheme.onSurfaceVariant;
    final fill = warn
        ? Color.alphaBlend(dsh.warningContainer.withValues(alpha: 0.94), scheme.surface)
        : scheme.surfaceContainerHighest;
    final edge = warn ? dsh.warning.withValues(alpha: 0.35) : scheme.outlineVariant;
    final name = permissionName(preset);
    const side = PermissionPillMetrics.inset;
    final glyph = Icon(
      warn ? AppIcons.permissionRisky : AppIcons.permissions,
      size: PermissionPillMetrics.icon,
      color: fg,
    );
    return Semantics(
      button: true,
      label: l10n.nearbyPermissionPill(name),
      excludeSemantics: true,
      child: Material(
        color: fill,
        shape: compact
            ? CircleBorder(side: BorderSide(color: edge, width: 0.5))
            : StadiumBorder(side: BorderSide(color: edge, width: 0.5)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: compact
              ? SizedBox.square(
                  dimension: PermissionPillMetrics.height,
                  child: Center(child: glyph),
                )
              : SizedBox(
                  height: PermissionPillMetrics.height,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: side),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        glyph,
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(color: fg),
                          ),
                        ),
                        const SizedBox(width: 4),
                        SizedBox.square(
                          dimension: PermissionPillMetrics.icon,
                          child: Icon(AppIcons.disclosure, size: 14, color: fg),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// 「自动允许中」 or the permission chip right of the activity strip while a
/// reply generates, instead of a row of its own above it: as high as the
/// strip. Its words show for the first seconds of each run, then only its
/// icons stay; it is read out whole all along, and a tap does what the pill's
/// does. Only 自动审查 comes here: it is the one preset whose chip warns.
class StripRiskChip extends StatefulWidget {
  const StripRiskChip({
    super.key,
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.onTap,
    this.closes = false,
  });

  /// 「自动允许中 ×」: a tap switches auto-approve off.
  factory StripRiskChip.autoApprove(BuildContext context, {Key? key, required VoidCallback onDisable}) =>
      StripRiskChip(
        key: key,
        icon: AppIcons.autoApprove,
        label: context.l10n.chatAutoApproving,
        semanticsLabel: context.l10n.chatAutoApproveCommands,
        onTap: onDisable,
        closes: true,
      );

  /// 「⚠ 自动审查」: a tap opens the conversation's permissions.
  factory StripRiskChip.permission(
    BuildContext context, {
    Key? key,
    required String preset,
    required VoidCallback onTap,
  }) => StripRiskChip(
    key: key,
    icon: AppIcons.permissionRisky,
    label: permissionName(preset),
    semanticsLabel: context.l10n.nearbyPermissionPill(permissionName(preset)),
    onTap: onTap,
  );

  final IconData icon;
  final String label;
  final String semanticsLabel;
  final VoidCallback onTap;

  /// Ends in ⓧ: the tap turns it off.
  final bool closes;

  /// The activity strip's height.
  static const height = 36.0;

  /// Chip edge → the end icons, the same on both sides.
  static const inset = 10.0;
  static const glyph = 16.0;

  /// How long its words show once it appears.
  static const wordsFor = Duration(seconds: 3);

  @override
  State<StripRiskChip> createState() => _StripRiskChipState();
}

class _StripRiskChipState extends State<StripRiskChip> {
  late final Timer _timer;
  bool _words = true;

  @override
  void initState() {
    super.initState();
    _timer = Timer(StripRiskChip.wordsFor, () {
      if (mounted) setState(() => _words = false);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final fg = dsh.onWarningContainer;
    return Semantics(
      button: true,
      label: widget.semanticsLabel,
      onTapHint: widget.closes ? l10n.commonClose : null,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: Material(
        color: Color.alphaBlend(dsh.warningContainer.withValues(alpha: 0.94), theme.colorScheme.surface),
        shape: StadiumBorder(side: BorderSide(color: dsh.warning.withValues(alpha: 0.35), width: 0.5)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          child: SizedBox(
            height: StripRiskChip.height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: StripRiskChip.inset),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, size: StripRiskChip.glyph, color: fg),
                  AnimatedSize(
                    duration: AppMotion.of(context, AppMotion.standard),
                    curve: AppMotion.std,
                    child: _words
                        ? Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              widget.label,
                              maxLines: 1,
                              softWrap: false,
                              style: theme.textTheme.labelMedium?.copyWith(color: fg),
                            ),
                          )
                        : const SizedBox(height: StripRiskChip.glyph),
                  ),
                  if (widget.closes) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: StripRiskChip.glyph,
                      height: StripRiskChip.glyph,
                      decoration: BoxDecoration(color: fg.withValues(alpha: 0.12), shape: BoxShape.circle),
                      child: Icon(AppIcons.close, size: 12, color: fg),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
