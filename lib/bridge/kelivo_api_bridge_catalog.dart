import '../core/providers/model_provider.dart';
import '../core/providers/settings_provider.dart';
import '../core/services/model_override_resolver.dart';

class KelivoApiBridgeModelCatalogItem {
  const KelivoApiBridgeModelCatalogItem({
    required this.providerKey,
    required this.providerName,
    required this.providerEnabled,
    required this.modelId,
    required this.displayName,
    required this.type,
    required this.input,
    required this.output,
    required this.abilities,
    required this.selected,
    this.apiModelId,
  });

  final String providerKey;
  final String providerName;
  final bool providerEnabled;
  final String modelId;
  final String displayName;
  final ModelType type;
  final List<Modality> input;
  final List<Modality> output;
  final List<ModelAbility> abilities;
  final bool selected;
  final String? apiModelId;

  Map<String, dynamic> toJson() {
    return {
      'providerKey': providerKey,
      'providerName': providerName,
      'providerEnabled': providerEnabled,
      'modelId': modelId,
      'displayName': displayName,
      'type': type.name,
      'input': input.map((item) => item.name).toList(growable: false),
      'output': output.map((item) => item.name).toList(growable: false),
      'abilities': abilities.map((item) => item.name).toList(growable: false),
      'selected': selected,
      'supportsImageInput': input.contains(Modality.image),
      'supportsReasoning': abilities.contains(ModelAbility.reasoning),
      'supportsTools': abilities.contains(ModelAbility.tool),
      'apiModelId': apiModelId,
    };
  }
}

List<KelivoApiBridgeModelCatalogItem> buildKelivoApiBridgeModelCatalog({
  required Map<String, ProviderConfig> providerConfigs,
  String? currentProviderKey,
  String? currentModelId,
}) {
  final items = <KelivoApiBridgeModelCatalogItem>[];

  for (final entry in providerConfigs.entries) {
    final providerKey = entry.key;
    final config = entry.value;
    final modelIds = <String>[];
    final seenModelIds = <String>{};

    void appendModelId(String raw) {
      final value = raw.trim();
      if (value.isEmpty || !seenModelIds.add(value)) return;
      modelIds.add(value);
    }

    for (final modelId in config.models) {
      appendModelId(modelId);
    }
    for (final modelId in config.modelOverrides.keys) {
      appendModelId(modelId);
    }

    for (final modelId in modelIds) {
      var info = ModelRegistry.infer(
        ModelInfo(id: modelId, displayName: modelId),
      );
      String? apiModelId;
      final rawOverride = config.modelOverrides[modelId];
      if (rawOverride is Map) {
        final override = rawOverride.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        info = ModelOverrideResolver.applyModelOverride(
          info,
          override,
          applyDisplayName: true,
        );
        final rawApiModelId =
            (override['apiModelId'] ?? override['api_model_id'])
                ?.toString()
                .trim();
        if (rawApiModelId != null && rawApiModelId.isNotEmpty) {
          apiModelId = rawApiModelId;
        }
      }

      items.add(
        KelivoApiBridgeModelCatalogItem(
          providerKey: providerKey,
          providerName: config.name.isNotEmpty ? config.name : providerKey,
          providerEnabled: config.enabled,
          modelId: modelId,
          displayName: info.displayName,
          type: info.type,
          input: info.input,
          output: info.output,
          abilities: info.abilities,
          selected:
              providerKey == currentProviderKey && modelId == currentModelId,
          apiModelId: apiModelId,
        ),
      );
    }
  }

  return items;
}
