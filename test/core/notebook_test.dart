import 'dart:convert';

import 'package:colabmate/models/notebook.dart';
import 'package:flutter_test/flutter_test.dart';

const _ipynb = '''
{
 "nbformat": 4,
 "nbformat_minor": 0,
 "metadata": {"colab": {"provenance": []}, "kernelspec": {"name": "python3"}},
 "cells": [
  {"cell_type": "markdown", "metadata": {"id": "a1"}, "source": ["# Title\\n", "Intro"]},
  {"cell_type": "code", "execution_count": 3, "metadata": {"id": "b2"},
   "source": "print('hi')\\nx = 1",
   "outputs": [
     {"output_type": "stream", "name": "stdout", "text": ["hi\\n"]},
     {"output_type": "execute_result", "data": {"text/plain": ["1"]}, "metadata": {}, "execution_count": 3}
   ]},
  {"cell_type": "code", "metadata": {}, "source": [], "outputs": [
     {"output_type": "error", "ename": "ValueError", "evalue": "bad", "traceback": []}
   ]}
 ]
}
''';

void main() {
  Notebook parse() =>
      Notebook.fromIpynb(id: 'f1', name: 'demo.ipynb', json: _ipynb);

  test('parses cells, joining list and string sources', () {
    final nb = parse();
    expect(nb.cells, hasLength(3));
    expect(nb.cells[0].type, CellType.markdown);
    expect(nb.cells[0].source, '# Title\nIntro');
    expect(nb.cells[1].type, CellType.code);
    expect(nb.cells[1].source, "print('hi')\nx = 1");
    expect(nb.cells[2].source, '');
  });

  test('output preview covers stream, results and errors', () {
    final nb = parse();
    expect(nb.cells[1].outputText, 'hi\n1');
    expect(nb.cells[2].outputText, 'ValueError: bad');
  });

  test('round-trip keeps metadata, outputs and unknown fields', () {
    final out = jsonDecode(parse().toIpynb()) as Map<String, dynamic>;
    final orig = jsonDecode(_ipynb) as Map<String, dynamic>;
    expect(out['metadata'], orig['metadata']);
    expect(out['nbformat'], 4);
    final cell = (out['cells'] as List)[1] as Map;
    expect(cell['execution_count'], 3);
    expect(cell['metadata'], {'id': 'b2'});
    expect(cell['outputs'], (orig['cells'] as List)[1]['outputs']);
    // Source written in Jupyter's list-of-lines form.
    expect(cell['source'], ["print('hi')\n", 'x = 1']);
  });

  test('serialisation is stable (parse → write → parse → write)', () {
    final once = parse().toIpynb();
    final twice = Notebook.fromIpynb(id: 'f1', name: 'n', json: once).toIpynb();
    expect(twice, once);
  });

  test('trailing newline and blank lines survive', () {
    final nb = parse().updateCell(1, 'a\n\nb\n');
    final again = Notebook.fromIpynb(id: 'f1', name: 'n', json: nb.toIpynb());
    expect(again.cells[1].source, 'a\n\nb\n');
  });

  test('updateCell changes only that cell', () {
    final nb = parse();
    final edited = nb.updateCell(1, 'print(2)');
    expect(edited.cells[1].source, 'print(2)');
    expect(edited.cells[0], nb.cells[0]);
    expect(nb.cells[1].source, "print('hi')\nx = 1", reason: 'immutable');
  });

  test('rejects files that are not notebooks', () {
    expect(
      () => Notebook.fromIpynb(id: 'x', name: 'x', json: 'not json'),
      throwsA(isA<NotebookParseException>()),
    );
    expect(
      () => Notebook.fromIpynb(id: 'x', name: 'x', json: '{"a": 1}'),
      throwsA(isA<NotebookParseException>()),
    );
  });
}
