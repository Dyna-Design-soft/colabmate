import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Thrown when a file is not a valid Jupyter notebook.
class NotebookParseException implements Exception {
  const NotebookParseException(this.message);
  final String message;
  @override
  String toString() => 'NotebookParseException: $message';
}

/// A notebook file as listed in Google Drive (no content).
@immutable
class NotebookMeta {
  const NotebookMeta({
    required this.id,
    required this.name,
    this.modifiedTime,
    this.mimeType,
    this.pendingSync = false,
  });

  final String id;
  final String name;
  final DateTime? modifiedTime;

  /// Drive MIME type (`application/vnd.google.colaboratory` for Colab files).
  /// Preserved on upload so Colab keeps recognising the file.
  final String? mimeType;

  /// True if this notebook has local edits not yet uploaded to Drive.
  final bool pendingSync;

  @override
  bool operator ==(Object other) =>
      other is NotebookMeta &&
      other.id == id &&
      other.name == name &&
      other.modifiedTime == modifiedTime &&
      other.mimeType == mimeType &&
      other.pendingSync == pendingSync;

  @override
  int get hashCode =>
      Object.hash(id, name, modifiedTime, mimeType, pendingSync);

  @override
  String toString() => 'NotebookMeta($id, $name)';
}

enum CellType {
  code,
  markdown,
  raw;

  static CellType parse(Object? value) => switch (value) {
    'code' => CellType.code,
    'markdown' => CellType.markdown,
    _ => CellType.raw,
  };
}

/// One notebook cell. Fields ColabMate doesn't use (outputs, metadata,
/// execution_count, …) are kept in [raw] and written back unchanged.
@immutable
class Cell {
  const Cell({required this.type, required this.source, this.raw = const {}});

  factory Cell.fromJson(Map<String, dynamic> json) => Cell(
    type: CellType.parse(json['cell_type']),
    source: _joinSource(json['source']),
    raw: Map.unmodifiable(json),
  );

  final CellType type;
  final String source;
  final Map<String, dynamic> raw;

  Cell copyWith({String? source}) =>
      Cell(type: type, source: source ?? this.source, raw: raw);

  /// Text of the cell's outputs (stream text and plain-text results), for a
  /// read-only preview.
  String get outputText {
    final outputs = raw['outputs'];
    if (outputs is! List) return '';
    final buffer = StringBuffer();
    for (final o in outputs.whereType<Map>()) {
      switch (o['output_type']) {
        case 'stream':
          buffer.write(_joinSource(o['text']));
        case 'execute_result' || 'display_data':
          final data = o['data'];
          if (data is Map && data['text/plain'] != null) {
            buffer.writeln(_joinSource(data['text/plain']));
          }
        case 'error':
          buffer.writeln('${o['ename']}: ${o['evalue']}');
      }
    }
    return buffer.toString().trimRight();
  }

  Map<String, dynamic> toJson() => {
    ...raw,
    'cell_type': raw['cell_type'] ?? type.name,
    'source': _splitSource(source),
  };

  static String _joinSource(Object? source) => switch (source) {
    String s => s,
    List l => l.map((e) => '$e').join(),
    _ => '',
  };

  /// Jupyter stores source as a list of lines, each keeping its trailing
  /// newline except the last.
  static List<String> _splitSource(String source) {
    if (source.isEmpty) return const [];
    final lines = source.split('\n');
    return [
      for (var i = 0; i < lines.length; i++)
        if (i < lines.length - 1) '${lines[i]}\n' else lines[i],
    ]..removeWhere((l) => l.isEmpty);
  }

  @override
  bool operator ==(Object other) =>
      other is Cell &&
      other.type == type &&
      other.source == source &&
      mapEquals(other.raw, raw);

  @override
  int get hashCode => Object.hash(type, source);
}

/// A parsed .ipynb notebook.
@immutable
class Notebook {
  const Notebook({
    required this.id,
    required this.name,
    required this.cells,
    this.mimeType,
    this.raw = const {},
    this.pendingSync = false,
  });

  /// Parses .ipynb JSON. Throws [NotebookParseException] if it isn't one.
  factory Notebook.fromIpynb({
    required String id,
    required String name,
    required String json,
    String? mimeType,
    bool pendingSync = false,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      throw NotebookParseException('Not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic> || decoded['cells'] is! List) {
      throw const NotebookParseException('Missing "cells" list');
    }
    return Notebook(
      id: id,
      name: name,
      mimeType: mimeType,
      pendingSync: pendingSync,
      raw: Map.unmodifiable(decoded),
      cells: List.unmodifiable([
        for (final c in decoded['cells'] as List)
          if (c is Map<String, dynamic>) Cell.fromJson(c),
      ]),
    );
  }

  final String id;
  final String name;
  final List<Cell> cells;
  final String? mimeType;

  /// Top-level notebook fields (metadata, nbformat, …), written back as-is.
  final Map<String, dynamic> raw;

  /// True if this copy has local edits not yet uploaded to Drive.
  final bool pendingSync;

  NotebookMeta get meta => NotebookMeta(
    id: id,
    name: name,
    mimeType: mimeType,
    pendingSync: pendingSync,
  );

  Notebook copyWith({List<Cell>? cells, bool? pendingSync}) => Notebook(
    id: id,
    name: name,
    mimeType: mimeType,
    raw: raw,
    cells: cells ?? this.cells,
    pendingSync: pendingSync ?? this.pendingSync,
  );

  /// Returns a copy with cell [index]'s source replaced.
  Notebook updateCell(int index, String source) => copyWith(
    cells: List.unmodifiable([
      for (var i = 0; i < cells.length; i++)
        i == index ? cells[i].copyWith(source: source) : cells[i],
    ]),
  );

  String toIpynb() => const JsonEncoder.withIndent(' ').convert({
    ...raw,
    'cells': [for (final c in cells) c.toJson()],
    'nbformat': raw['nbformat'] ?? 4,
    'nbformat_minor': raw['nbformat_minor'] ?? 0,
    'metadata': raw['metadata'] ?? const <String, dynamic>{},
  });
}
