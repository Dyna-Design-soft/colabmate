import 'package:flutter/foundation.dart';

/// One piece of output streamed from a running cell (spec §4.3).
@immutable
sealed class OutputChunk {
  const OutputChunk();
}

/// Text printed to stdout / stderr.
class StreamChunk extends OutputChunk {
  const StreamChunk(this.name, this.text);

  /// `stdout` or `stderr`.
  final String name;
  final String text;

  bool get isError => name == 'stderr';

  @override
  bool operator ==(Object other) =>
      other is StreamChunk && other.name == name && other.text == text;

  @override
  int get hashCode => Object.hash(name, text);

  @override
  String toString() => 'StreamChunk($name, ${text.trim()})';
}

/// A rich result (`execute_result` / `display_data`): MIME type → data.
class RichChunk extends OutputChunk {
  const RichChunk(this.data, {this.executionCount});

  final Map<String, dynamic> data;
  final int? executionCount;

  String? get plainText => _join(data['text/plain']);

  /// Base64 PNG, if the output is an image (e.g. a matplotlib plot).
  String? get pngBase64 => _join(data['image/png'])?.replaceAll('\n', '');

  static String? _join(Object? v) => switch (v) {
    String s => s,
    List l => l.join(),
    _ => null,
  };

  @override
  String toString() => 'RichChunk(${data.keys.join(', ')})';
}

/// An exception raised by the cell.
class ErrorChunk extends OutputChunk {
  const ErrorChunk(this.ename, this.evalue, this.traceback);

  final String ename;
  final String evalue;

  /// Traceback lines (may contain ANSI colour codes; see [plainTraceback]).
  final List<String> traceback;

  static final RegExp _ansi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

  String get plainTraceback =>
      traceback.map((l) => l.replaceAll(_ansi, '')).join('\n');

  @override
  bool operator ==(Object other) =>
      other is ErrorChunk && other.ename == ename && other.evalue == evalue;

  @override
  int get hashCode => Object.hash(ename, evalue);

  @override
  String toString() => 'ErrorChunk($ename: $evalue)';
}

/// The cell finished. Always the last chunk of an execution.
class DoneChunk extends OutputChunk {
  const DoneChunk({required this.ok, this.executionCount, this.elapsed});

  /// False if the cell raised an error (or was aborted).
  final bool ok;
  final int? executionCount;
  final Duration? elapsed;

  @override
  bool operator ==(Object other) =>
      other is DoneChunk &&
      other.ok == ok &&
      other.executionCount == executionCount;

  @override
  int get hashCode => Object.hash(ok, executionCount);

  @override
  String toString() => 'DoneChunk(ok: $ok, [$executionCount])';
}
