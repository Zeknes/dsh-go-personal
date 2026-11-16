// The header's 「N 个子代理」 sheet (DSH Web opens the
// same catalog as a dropdown under its session header).
//
// A long-lived conversation can collect thousands of children, so the sheet
// opens on the recent ones (every running child included) and builds rows
// lazily; the rest is one row away, or a search over the whole lineage.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/agents_state.dart';
import '../../state/sessions_state.dart';
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/feature_tile.dart';
import '../common/list_page_row.dart';
import '../common/search_capsule.dart';
import '../common/sheet_title_bar.dart';
import '../theme/theme.dart';
import 'agent_widgets.dart';

/// The lineage under [sessionId] as a sheet; a row opens that conversation.
Future<void> showLineageSheet(BuildContext context, {required String sessionId}) {
  // Fresh activity for the rows (the list hints refresh on status events).
  ProviderScope.containerOf(context, listen: false).read(sessionsProvider.notifier).refresh().ignore();
  return showAppSheet<void>(context, isScrollControlled: true, builder: (_) => LineageSheet(sessionId: sessionId));
}

class LineageSheet extends ConsumerStatefulWidget {
  const LineageSheet({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<LineageSheet> createState() => _LineageSheetState();
}

class _LineageSheetState extends ConsumerState<LineageSheet> {
  final _search = TextEditingController();
  String _query = '';
  bool _expanded = false;

  /// Key of the row that shows or folds the rest.
  static const _moreKey = ValueKey('lineage-more');

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final nodes = ref.watch(subagentLineageProvider(widget.sessionId));
    final total = lineageSize(nodes);
    final searchable = total > recentLineageLimit;
    final rows = visibleLineage(nodes, query: _query, expanded: _expanded);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final hidden = total - rows.length;
    final more = _query.trim().isEmpty && (hidden > 0 || _expanded && total > recentLineageLimit);
    // Same key the item keeps when the order changes under it: the element
    // (its timer, its animation) follows the node, not the position.
    final indexOf = <Key, int>{
      for (final (i, row) in rows.indexed) ValueKey(row.node.id): i,
      if (more) _moreKey: rows.length,
    };
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(nodes.isEmpty ? l10n.botsSubagents : lineageTitle(nodes)),
          if (lineageSubtitle(nodes) != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
              child: Align(alignment: Alignment.centerLeft, child: LineageSummary(nodes: nodes)),
            ),
          if (searchable)
            Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 8),
              child: SearchCapsule(
                controller: _search,
                hint: l10n.botsSubagentsSearch,
                onChanged: (value) => setState(() => _query = value),
                onClear: () => setState(() {
                  _search.clear();
                  _query = '';
                }),
              ),
            ),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 6),
              child: nodes.isEmpty
                  ? EmptyView(
                      art: FeatureTile(FeatureKind.subagents, size: FeatureTile.compact),
                      title: l10n.botsNoSubagents,
                      compact: true,
                    )
                  : GlassSurface(
                      tier: GlassTier.card,
                      borderRadius: AppShape.radiusLg,
                      child: Material(
                        type: MaterialType.transparency,
                        clipBehavior: Clip.antiAlias,
                        shape: const RoundedSuperellipseBorder(borderRadius: AppShape.radiusLg),
                        child: rows.isEmpty
                            ? Padding(
                                padding: EdgeInsets.fromLTRB(ListPageRow.horizontal, 20, ListPageRow.trailingPad, 20 + bottom),
                                child: Text(
                                  l10n.botsSubagentsNoMatch,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.bodyMedium?.copyWith(color: DshColors.of(context).textTertiary),
                                ),
                              )
                            : ListView.builder(
                                // A short lineage hugs its rows; a long one
                                // fills the sheet and builds as it scrolls.
                                shrinkWrap: rows.length <= recentLineageLimit,
                                padding: EdgeInsets.only(top: 4, bottom: 4 + bottom + 16),
                                itemCount: rows.length + (more ? 1 : 0),
                                // Keep each built row with its node when the
                                // order changes (a child starts or finishes).
                                findChildIndexCallback: (key) => indexOf[key],
                                itemBuilder: (context, index) {
                                  if (index >= rows.length) {
                                    return LineageCountRow(
                                      key: _moreKey,
                                      total: total,
                                      expanded: _expanded,
                                      onTap: () => setState(() => _expanded = !_expanded),
                                    );
                                  }
                                  final row = rows[index];
                                  return SubagentRow(
                                    key: ValueKey(row.node.id),
                                    node: row.node,
                                    depth: row.depth,
                                    onOpen: (node) {
                                      selectSubagent(ref, node.address);
                                      Navigator.of(context).pop();
                                    },
                                  );
                                },
                              ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
