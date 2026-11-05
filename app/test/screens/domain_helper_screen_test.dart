import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/models/custom_rule.dart';
import 'package:lxbox/screens/domain_helper_screen.dart';
import 'package:lxbox/services/domain_helper/public_suffix.dart';

/// §724 — экран помощника: текст → группы → покрытие → выход → результат.
void main() {
  final psl = PublicSuffixList.parse(
    File(PublicSuffixList.assetPath).readAsStringSync(),
  );

  testWidgets('paste text, check exits, add returns suffixes and domains', (
    t,
  ) async {
    DomainHelperResult? result;
    final deps = DomainHelperDeps(
      loadPsl: () async => psl,
      loadRules: () async => [
        CustomRuleInline(
          name: 'Old',
          domainSuffixes: ['gitlab.com'],
          outbound: 'vpn-1',
        ),
      ],
      tunnelConnected: () => true,
      proxyTag: () => 'vpn-1',
      probe: (tag, url, ms) async =>
          url.contains('gitlab') && tag == 'direct-out'
          ? (0, 'i/o timeout')
          : (200, ''),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.push<DomainHelperResult>(
                  ctx,
                  MaterialPageRoute(
                    builder: (_) => DomainHelperScreen(deps: deps),
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
    await t.pumpAndSettle();

    await t.tap(find.text('Paste text'));
    await t.pumpAndSettle();
    await t.enterText(
      find.byType(TextField),
      'github.com, api.github.com, release-assets.githubusercontent.com, gitlab.com',
    );
    await t.tap(find.text('Extract'));
    await t.pumpAndSettle();

    // github.com + api.github.com → одна группа-суффикс; общий хостинг — точно.
    expect(find.text('suffix github.com'), findsOneWidget);
    expect(find.text('release-assets.githubusercontent.com'), findsWidgets);
    expect(
      find.textContaining('Already matched by rule «Old» → vpn-1'),
      findsOneWidget,
    );

    await t.tap(find.text('Check exits'));
    await t.pumpAndSettle();
    expect(find.text('Works direct'), findsNWidgets(2));
    expect(find.text('Only via proxy'), findsOneWidget);

    // gitlab.com уже ловится другим правилом — снимаем галку.
    await t.tap(find.text('gitlab.com').first);
    await t.pumpAndSettle();
    await t.tap(find.text('Add (2)'));
    await t.pumpAndSettle();

    expect(result!.suffixes, ['github.com']);
    expect(result!.domains, ['release-assets.githubusercontent.com']);
  });
}
