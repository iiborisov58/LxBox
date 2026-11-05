import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lxbox/screens/rule_set_finder_screen.dart';
import 'package:lxbox/services/rule_sets/rule_set_catalog.dart';
import 'package:lxbox/services/rule_sets/rule_set_sources.dart';

/// §723 — экран поиска: список, фильтр, карточка, «Использовать».
void main() {
  const reg = RuleSetSources([
    RuleSetSource(
      id: 'src',
      title: 'Src',
      repo: 'o/r',
      ref: 'main',
      dirs: [RuleSetSourceDir('geo', RuleSetKind.geosite)],
    ),
  ], Duration(hours: 24));

  testWidgets('search narrows the list, Use returns the raw URL', (t) async {
    final tmp = Directory.systemTemp.createTempSync('rsf');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'tree': [
            {'path': 'youtube.srs', 'type': 'blob', 'size': 2048},
            {'path': 'telegram.srs', 'type': 'blob', 'size': 10},
          ],
        }),
        200,
      ),
    );
    final catalog = RuleSetCatalog(
      client: client,
      cacheFile: () async => File('${tmp.path}/c.json'),
    );

    String? picked;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () async {
                picked = await Navigator.push<String>(
                  ctx,
                  MaterialPageRoute(
                    builder: (_) =>
                        RuleSetFinderScreen(catalog: catalog, sources: reg),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pump();
    // Загрузка — настоящий файловый I/O кеша: ему нужен реальный цикл событий.
    for (
      var i = 0;
      i < 20 && find.text('youtube.srs').evaluate().isEmpty;
      i++
    ) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }
    await t.pumpAndSettle();

    expect(find.text('youtube.srs'), findsOneWidget);
    expect(find.text('telegram.srs'), findsOneWidget);

    await t.enterText(find.byType(TextField), 'tele');
    await t.pump();
    expect(find.text('youtube.srs'), findsNothing);

    await t.tap(find.text('telegram.srs'));
    await t.pumpAndSettle();
    expect(
      find.textContaining(
        'raw.githubusercontent.com/o/r/main/geo/telegram.srs',
      ),
      findsOneWidget,
    );
    await t.tap(find.text('Use'));
    await t.pumpAndSettle();
    expect(
      picked,
      'https://raw.githubusercontent.com/o/r/main/geo/telegram.srs',
    );
  });
}
