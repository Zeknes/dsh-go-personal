// Where a shared conversation goes — a `.dshgo` file, a self-contained `.html`
// or Markdown (the Android share sheet, or Download/DSH-Go), plain text, or a
// hosted link (the share host's client, app/lib/share_hosted/). Seams: tests
// record instead.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/l10n.dart';
import '../../share_code/conversation_html.dart';
import '../../share_code/conversation_share.dart' show prefixKeepingPairs;
import '../../share_code/share_codec.dart' show shareFileExtension, shareFileMime;
import '../../state/artifacts.dart' show FilesChannel, filesChannelProvider;

/// The file forms of a shared conversation.
enum ConversationFormat {
  /// `.dshgo`: opens in dsh-go (replay, 「接着聊」) and on the landing page.
  file,

  /// `.html`: opens in any browser, offline.
  page,

  /// `.md`: who said what, one line per tool call (what 「接着聊」 attaches).
  markdown;

  String get extension => switch (this) {
    file => shareFileExtension,
    page => 'html',
    markdown => 'md',
  };

  String get mime => switch (this) {
    file => shareFileMime,
    page => conversationHtmlMime,
    markdown => 'text/markdown',
  };

  /// Carries the `.dshgo` file (and so its size limit).
  bool get carriesFile => this != markdown;
}

class ConversationOut {
  ConversationOut({
    required this.files,
    Future<Directory> Function()? cacheRoot,
    Future<void> Function(ShareParams params)? share,
  }) : _cacheRoot = cacheRoot ?? getTemporaryDirectory,
       _share = share ?? _systemShare;

  final FilesChannel files;
  final Future<Directory> Function() _cacheRoot;
  final Future<void> Function(ShareParams params) _share;

  static Future<void> _systemShare(ShareParams params) async {
    await SharePlus.instance.share(params);
  }

  /// 「修复登录重复提交.dshgo」.
  static String fileName(String title, ConversationFormat format) => '${fileStem(title)}.${format.extension}';

  /// Writes [content] into the cache's `conversation/` (keeping the last few).
  Future<File> write(String name, String content) async {
    final dir = Directory('${(await _cacheRoot()).path}/conversation');
    await dir.create(recursive: true);
    final old = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    for (final file in old.skip(4)) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
    final file = File('${dir.path}/$name');
    await file.writeAsString(content, flush: true);
    return file;
  }

  /// The Android share sheet with the file.
  Future<void> shareFile(File file, ConversationFormat format) => _share(
    ShareParams(
      files: [XFile(file.path, mimeType: format.mime, name: file.uri.pathSegments.last)],
    ),
  );

  /// The Android share sheet with a link.
  Future<void> shareText(String text) => _share(ShareParams(text: text));

  /// Into `Download/DSH-Go`; returns where it landed.
  Future<String> save(String name, String content, ConversationFormat format) async {
    final dir = await Directory('${(await _cacheRoot()).path}/conversation').create(recursive: true);
    // A dismissed sheet can reopen before the native worker reads its source.
    final operation = await dir.createTemp('save-');
    try {
      final file = File('${operation.path}/$name');
      await file.writeAsString(content, flush: true);
      return await files.saveToDownloads(file.path, name: name, mime: format.mime);
    } finally {
      try {
        await operation.delete(recursive: true);
      } catch (_) {
        // Cleanup must preserve the native result or the original save error.
      }
    }
  }
}

final conversationOutProvider = Provider<ConversationOut>(
  (ref) => ConversationOut(files: ref.watch(filesChannelProvider)),
);

/// A file name from a title: no path characters, at most 40 characters.
String fileStem(String title) {
  final cleaned = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.isEmpty) return appL10n.fileChatFallback;
  return cleaned.length <= 40 ? cleaned : prefixKeepingPairs(cleaned, 40).trim();
}
