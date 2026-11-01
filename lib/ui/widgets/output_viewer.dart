import 'dart:convert';

import 'package:flutter/material.dart';

import '../../models/output_chunk.dart';
import '../../providers/runtime_provider.dart';

/// Streaming output of a cell run (spec widget `output_viewer.dart`):
/// stdout/stderr text, rich results (text + PNG images) and errors.
class OutputViewer extends StatelessWidget {
  const OutputViewer({super.key, required this.run});

  final CellRun run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      color: theme.colorScheme.onSurface,
    );
    final children = <Widget>[];
    final buffer = StringBuffer();

    void flushText() {
      if (buffer.isEmpty) return;
      children.add(SelectableText(buffer.toString().trimRight(), style: mono));
      buffer.clear();
    }

    for (final chunk in run.chunks) {
      switch (chunk) {
        case StreamChunk(text: final t) when chunk.isError:
          flushText();
          children.add(
            SelectableText(
              t.trimRight(),
              style: mono.copyWith(color: theme.colorScheme.error),
            ),
          );
        case StreamChunk(text: final t):
          buffer.write(t);
        case RichChunk():
          flushText();
          final png = chunk.pngBase64;
          if (png != null) {
            children.add(
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Image.memory(base64Decode(png), gaplessPlayback: true),
              ),
            );
          } else if (chunk.plainText case final String t) {
            children.add(SelectableText(t, style: mono));
          }
        case ErrorChunk():
          flushText();
          children.add(
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.symmetric(vertical: 4),
              color: theme.colorScheme.errorContainer,
              child: SelectableText(
                chunk.traceback.isEmpty
                    ? '${chunk.ename}: ${chunk.evalue}'
                    : chunk.plainTraceback,
                style: mono.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          );
        case DoneChunk():
          break;
      }
    }
    flushText();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...children,
        if (run.running)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: SizedBox(
              width: 80,
              child: LinearProgressIndicator(minHeight: 2),
            ),
          ),
      ],
    );
  }
}
