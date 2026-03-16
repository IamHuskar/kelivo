import 'package:flutter_test/flutter_test.dart';
import 'package:Kelivo/bridge/kelivo_api_bridge_catalog.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';

void main() {
  test('buildKelivoApiBridgeModelCatalog merges override-only models', () {
    final items = buildKelivoApiBridgeModelCatalog(
      providerConfigs: {
        'Demo': ProviderConfig(
          id: 'Demo',
          enabled: true,
          name: 'Demo Provider',
          apiKey: '',
          baseUrl: 'https://example.com/v1',
          models: const ['plain-model'],
          modelOverrides: const {
            'plain-model': {
              'name': 'Plain Display',
              'abilities': ['tool'],
            },
            'vision-reasoning': {
              'name': 'Vision Reasoning',
              'input': ['text', 'image'],
              'abilities': ['reasoning'],
              'apiModelId': 'vendor-vision-reasoning',
            },
          },
        ),
      },
      currentProviderKey: 'Demo',
      currentModelId: 'vision-reasoning',
    );

    expect(items, hasLength(2));

    final overrideOnly = items.firstWhere(
      (item) => item.modelId == 'vision-reasoning',
    );
    expect(overrideOnly.providerKey, 'Demo');
    expect(overrideOnly.displayName, 'Vision Reasoning');
    expect(overrideOnly.selected, isTrue);
    expect(overrideOnly.input.map((item) => item.name), contains('image'));
    expect(
      overrideOnly.abilities.map((item) => item.name),
      contains('reasoning'),
    );
    expect(overrideOnly.apiModelId, 'vendor-vision-reasoning');

    final plain = items.firstWhere((item) => item.modelId == 'plain-model');
    expect(plain.displayName, 'Plain Display');
    expect(plain.abilities.map((item) => item.name), contains('tool'));
  });
}
