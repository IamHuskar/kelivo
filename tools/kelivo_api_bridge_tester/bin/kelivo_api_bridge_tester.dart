import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const String _defaultBaseUrl = 'http://127.0.0.1:39321/api/bridge/v1';
const String _tinyPngDataUrl =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WnJxN8AAAAASUVORK5CYII=';

Future<void> main(List<String> args) async {
  final baseUrl = args.isNotEmpty ? args.first : _defaultBaseUrl;
  final api = _BridgeClient(baseUrl);

  String? createdConversationId;
  String? originalAssistantId;
  String? originalProviderKey;
  String? originalModelId;
  int? originalThinkingBudget;
  var bridgeReachable = false;
  var failed = false;

  try {
    final status = await api.get('/status');
    bridgeReachable = true;
    _printStep('status', status);

    final currentAssistant = await api.get('/assistants/current');
    _printStep('current assistant', currentAssistant);
    originalAssistantId = _readString(currentAssistant['data'], 'id');

    final assistants = await api.get('/assistants');
    _printStep('assistants', assistants);
    final assistantList = _readList(assistants['data']);
    if (assistantList.isEmpty) {
      throw StateError('No assistants available.');
    }

    final selectedAssistant = assistantList.firstWhere(
      (item) => item['usesDedicatedModel'] != true,
      orElse: () => assistantList.first,
    );
    final assistantId = _readString(selectedAssistant, 'id');
    final selectAssistant = await api.post('/assistants/current', {
      'assistantId': assistantId,
    });
    _printStep('select assistant', selectAssistant);

    final currentModel = await api.get('/models/current');
    _printStep('current model', currentModel);
    originalProviderKey = _readString(
      currentModel['data'],
      'globalProviderKey',
    );
    originalModelId = _readString(currentModel['data'], 'globalModelId');

    final models = await api.get('/models');
    _printStep('models', models);
    final modelList = _readList(models['data']);
    final chatModels = modelList
        .where((item) => item['type'] == 'chat')
        .toList(growable: false);
    if (chatModels.isEmpty) {
      throw StateError('No chat models available.');
    }

    final chosenModel = chatModels.firstWhere(
      (item) => item['providerEnabled'] == true,
      orElse: () => chatModels.first,
    );
    final selectModel = await api.post('/models/current', {
      'providerKey': chosenModel['providerKey'],
      'modelId': chosenModel['modelId'],
    });
    _printStep('select model', selectModel);

    final reasoning = await api.get('/reasoning');
    _printStep('reasoning', reasoning);
    originalThinkingBudget = _readInt(
      reasoning['data'],
      'globalThinkingBudget',
    );
    final setReasoning = await api.post('/reasoning', {
      'thinkingBudget': originalThinkingBudget,
    });
    _printStep('set reasoning', setReasoning);

    final createConversation = await api.post('/conversations', {
      'title': 'API Tester ${DateTime.now().toIso8601String()}',
      'assistantId': assistantId,
    });
    _printStep('create conversation', createConversation);
    createdConversationId = _readString(createConversation['data'], 'id');

    final sendText = await api.post('/messages/send', {
      'conversationId': createdConversationId,
      'text': 'Reply with one short sentence: Kelivo API bridge tester.',
    });
    _printStep('send text', sendText);

    final messages = await api.get(
      '/conversations/$createdConversationId/messages',
    );
    _printStep('list messages', messages);
    final messageList = _readList(messages['data']);
    if (messageList.length < 2) {
      throw StateError('Expected at least 2 messages after text send.');
    }

    final imageCapableModel = chatModels.firstWhere(
      (item) => item['supportsImageInput'] == true,
      orElse: () => const <String, dynamic>{},
    );
    if (imageCapableModel.isNotEmpty &&
        selectedAssistant['usesDedicatedModel'] != true) {
      final switchImageModel = await api.post('/models/current', {
        'providerKey': imageCapableModel['providerKey'],
        'modelId': imageCapableModel['modelId'],
      });
      _printStep('switch image model', switchImageModel);

      final sendImage = await api.post('/messages/send', {
        'conversationId': createdConversationId,
        'text': 'Describe the image briefly.',
        'imagePaths': <String>[_tinyPngDataUrl],
      });
      _printStep('send image', sendImage);
    } else {
      stdout.writeln('== send image ==');
      stdout.writeln(
        'Skipped: no image-capable chat model, or assistant uses a dedicated model.',
      );
    }
  } on SocketException catch (error) {
    stderr.writeln('Cannot connect to bridge at $baseUrl: $error');
    stderr.writeln(
      'Start Kelivo first and wait for the local bridge to listen.',
    );
    exitCode = 1;
    return;
  } catch (error, stackTrace) {
    stderr.writeln('Tester failed: $error');
    stderr.writeln(stackTrace);
    failed = true;
  } finally {
    if (bridgeReachable) {
      if (createdConversationId != null) {
        try {
          final deleted = await api.delete(
            '/conversations/$createdConversationId',
          );
          _printStep('delete conversation', deleted);
        } catch (error) {
          stderr.writeln('Cleanup failed for conversation: $error');
          failed = true;
        }
      }

      if (originalAssistantId != null) {
        try {
          final restoredAssistant = await api.post('/assistants/current', {
            'assistantId': originalAssistantId,
          });
          _printStep('restore assistant', restoredAssistant);
        } catch (error) {
          stderr.writeln('Restore assistant failed: $error');
          failed = true;
        }
      }

      if (originalProviderKey != null && originalModelId != null) {
        try {
          final restoredModel = await api.post('/models/current', {
            'providerKey': originalProviderKey,
            'modelId': originalModelId,
          });
          _printStep('restore model', restoredModel);
        } catch (error) {
          stderr.writeln('Restore model failed: $error');
          failed = true;
        }
      }

      try {
        final restoredReasoning = await api.post('/reasoning', {
          'thinkingBudget': originalThinkingBudget,
        });
        _printStep('restore reasoning', restoredReasoning);
      } catch (error) {
        stderr.writeln('Restore reasoning failed: $error');
        failed = true;
      }
    }

    api.close();
  }

  if (failed) {
    exitCode = 1;
  }
}

class _BridgeClient {
  _BridgeClient(String baseUrl)
    : _baseUri = Uri.parse(baseUrl.endsWith('/') ? baseUrl : '$baseUrl/'),
      _client = http.Client();

  final Uri _baseUri;
  final http.Client _client;

  Future<Map<String, dynamic>> get(String path) async {
    final response = await _client.get(_resolve(path));
    return _decode(response);
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _client.post(
      _resolve(path),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> delete(String path) async {
    final response = await _client.delete(_resolve(path));
    return _decode(response);
  }

  void close() {
    _client.close();
  }

  Uri _resolve(String path) {
    final normalized = path.startsWith('/') ? path.substring(1) : path;
    return _baseUri.resolve(normalized);
  }
}

Map<String, dynamic> _decode(http.Response response) {
  final body = response.body.isEmpty
      ? <String, dynamic>{}
      : (jsonDecode(response.body) as Map).cast<String, dynamic>();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw HttpException(
      'HTTP ${response.statusCode}: ${jsonEncode(body)}',
      uri: response.request?.url,
    );
  }
  return body;
}

List<Map<String, dynamic>> _readList(dynamic value) {
  if (value is! List) return const <Map<String, dynamic>>[];
  return value
      .whereType<Map>()
      .map((item) => item.cast<String, dynamic>())
      .toList(growable: false);
}

String? _readString(dynamic value, String key) {
  if (value is! Map) return null;
  final mapped = value.cast<String, dynamic>();
  final raw = mapped[key];
  if (raw == null) return null;
  final text = raw.toString();
  return text.isEmpty ? null : text;
}

int? _readInt(dynamic value, String key) {
  if (value is! Map) return null;
  final mapped = value.cast<String, dynamic>();
  final raw = mapped[key];
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return null;
}

void _printStep(String title, Map<String, dynamic> payload) {
  stdout.writeln('== $title ==');
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
}
