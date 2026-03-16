import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../core/models/assistant.dart';
import '../core/models/chat_input_data.dart';
import '../core/models/chat_message.dart';
import '../core/models/conversation.dart';
import '../core/providers/assistant_provider.dart';
import '../core/providers/settings_provider.dart';
import '../core/services/chat/chat_service.dart';
import '../core/services/logging/flutter_logger.dart';
import '../features/home/controllers/chat_controller.dart';
import '../features/home/controllers/generation_controller.dart';
import '../features/home/controllers/home_view_model.dart';
import '../features/home/controllers/stream_controller.dart' as stream_ctrl;
import '../features/home/services/message_builder_service.dart';
import '../features/home/services/message_generation_service.dart';
import '../features/home/services/ocr_service.dart';
import '../l10n/app_localizations.dart';
import 'kelivo_api_bridge_catalog.dart';

class KelivoApiBridgeService {
  KelivoApiBridgeService._();

  static final KelivoApiBridgeService instance = KelivoApiBridgeService._();

  static const String host = '127.0.0.1';
  static const int port = 39321;
  static const Duration _sendTimeout = Duration(minutes: 10);

  bool _starting = false;
  bool _started = false;
  BuildContext? _context;

  ChatService? _chatService;
  ChatController? _chatController;
  stream_ctrl.StreamController? _streamController;
  MessageBuilderService? _messageBuilderService;
  HomeViewModel? _viewModel;

  String? _lastError;
  String? _lastWarning;
  Future<void> _serial = Future<void>.value();

  Future<void> start(BuildContext context) async {
    if (kIsWeb || _started || _starting) return;
    _starting = true;
    try {
      final assistantProvider = context.read<AssistantProvider>();
      final chatService = context.read<ChatService>();
      _context = context;
      await assistantProvider.ensureDefaults(context);
      if (!context.mounted) return;
      await chatService.init();
      if (!context.mounted) return;
      _chatService = chatService;
      _initializeHeadlessControllers(context, chatService);

      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: true,
      );
      server.autoCompress = true;
      server.listen(
        (request) {
          unawaited(_handleRequest(request));
        },
        onError: (Object error, StackTrace stackTrace) {
          FlutterLogger.log(
            '[ApiBridge] Server stream error: $error\n$stackTrace',
            tag: 'ApiBridge',
          );
        },
      );
      _started = true;
      FlutterLogger.log(
        '[ApiBridge] Listening on http://$host:$port/api/bridge/v1',
        tag: 'ApiBridge',
      );
    } catch (error, stackTrace) {
      FlutterLogger.log(
        '[ApiBridge] Failed to start: $error\n$stackTrace',
        tag: 'ApiBridge',
      );
    } finally {
      _starting = false;
    }
  }

  void _initializeHeadlessControllers(
    BuildContext context,
    ChatService chatService,
  ) {
    if (_viewModel != null) return;

    final ocrService = OcrService();
    final chatController = ChatController(chatService: chatService);
    final streamController = stream_ctrl.StreamController(
      chatService: chatService,
      onStateChanged: () {},
      getSettingsProvider: () => context.read<SettingsProvider>(),
      getCurrentConversationId: () => chatController.currentConversation?.id,
    );
    final messageBuilderService = MessageBuilderService(
      chatService: chatService,
      contextProvider: context,
      ocrHandler: (imagePaths) =>
          ocrService.getOcrTextForImages(imagePaths, context),
      geminiThoughtSignatureHandler:
          streamController.appendGeminiThoughtSignatureForApi,
    );
    messageBuilderService.ocrTextWrapper = ocrService.wrapOcrBlock;
    final generationController = GenerationController(
      chatService: chatService,
      chatController: chatController,
      streamController: streamController,
      messageBuilderService: messageBuilderService,
      contextProvider: context,
      onStateChanged: () {},
      getTitleForLocale: _titleForLocale,
    );
    final messageGenerationService = MessageGenerationService(
      chatService: chatService,
      messageBuilderService: messageBuilderService,
      generationController: generationController,
      streamController: streamController,
      contextProvider: context,
    );
    final viewModel = HomeViewModel(
      chatService: chatService,
      messageBuilderService: messageBuilderService,
      messageGenerationService: messageGenerationService,
      generationController: generationController,
      streamController: streamController,
      chatController: chatController,
      contextProvider: context,
      getTitleForLocale: _titleForLocale,
    );
    viewModel.onError = (error) {
      _lastError = error;
    };
    viewModel.onWarning = (warning) {
      _lastWarning = warning;
    };
    viewModel.onScheduleImageSanitize =
        (messageId, content, {bool immediate = false}) {
          _scheduleInlineImageSanitize(
            messageId,
            latestContent: content,
            immediate: immediate,
          );
        };

    _chatController = chatController;
    _streamController = streamController;
    _messageBuilderService = messageBuilderService;
    _viewModel = viewModel;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    _setCorsHeaders(response);

    if (!_started) {
      await _writeJson(
        response,
        HttpStatus.serviceUnavailable,
        _error('bridge_not_started'),
      );
      return;
    }

    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    try {
      final pathSegments = request.uri.pathSegments;
      if (pathSegments.length < 3 ||
          pathSegments[0] != 'api' ||
          pathSegments[1] != 'bridge' ||
          pathSegments[2] != 'v1') {
        throw _ApiBridgeException('not_found', statusCode: HttpStatus.notFound);
      }
      final segments = pathSegments.sublist(3);
      final method = request.method.toUpperCase();

      if (segments.isEmpty ||
          (segments.length == 1 && segments[0] == 'status')) {
        _expectMethod(method, 'GET');
        await _writeJson(response, HttpStatus.ok, {
          'ok': true,
          'data': _status(),
        });
        return;
      }

      if (segments.length == 1 && segments[0] == 'assistants') {
        _expectMethod(method, 'GET');
        await _writeJson(response, HttpStatus.ok, {
          'ok': true,
          'data': _listAssistants(),
        });
        return;
      }

      if (segments.length == 2 &&
          segments[0] == 'assistants' &&
          segments[1] == 'current') {
        if (method == 'GET') {
          await _writeJson(response, HttpStatus.ok, {
            'ok': true,
            'data': _currentAssistantState(),
          });
          return;
        }
        _expectMethod(method, 'POST');
        final body = await _readJsonObject(request);
        final result = await _enqueue(
          () => _selectAssistant(_requireString(body, 'assistantId')),
        );
        await _writeJson(response, HttpStatus.ok, {'ok': true, 'data': result});
        return;
      }

      if (segments.length == 1 && segments[0] == 'models') {
        _expectMethod(method, 'GET');
        await _writeJson(response, HttpStatus.ok, {
          'ok': true,
          'data': _listModels(),
        });
        return;
      }

      if (segments.length == 2 &&
          segments[0] == 'models' &&
          segments[1] == 'current') {
        if (method == 'GET') {
          await _writeJson(response, HttpStatus.ok, {
            'ok': true,
            'data': _currentModelState(),
          });
          return;
        }
        _expectMethod(method, 'POST');
        final body = await _readJsonObject(request);
        final result = await _enqueue(
          () => _selectModel(
            _requireString(body, 'providerKey'),
            _requireString(body, 'modelId'),
          ),
        );
        await _writeJson(response, HttpStatus.ok, {'ok': true, 'data': result});
        return;
      }

      if (segments.length == 1 && segments[0] == 'reasoning') {
        if (method == 'GET') {
          await _writeJson(response, HttpStatus.ok, {
            'ok': true,
            'data': _reasoningState(),
          });
          return;
        }
        _expectMethod(method, 'POST');
        final body = await _readJsonObject(request);
        final result = await _enqueue(
          () => _setThinkingBudget(body['thinkingBudget']),
        );
        await _writeJson(response, HttpStatus.ok, {'ok': true, 'data': result});
        return;
      }

      if (segments.length == 1 && segments[0] == 'conversations') {
        if (method == 'GET') {
          await _writeJson(response, HttpStatus.ok, {
            'ok': true,
            'data': _listConversations(),
          });
          return;
        }
        _expectMethod(method, 'POST');
        final body = await _readJsonObject(request);
        final result = await _enqueue(
          () => _createConversation(
            title: _optionalString(body['title']),
            assistantId: _optionalString(body['assistantId']),
          ),
        );
        await _writeJson(response, HttpStatus.created, {
          'ok': true,
          'data': result,
        });
        return;
      }

      if (segments.length == 2 && segments[0] == 'conversations') {
        _expectMethod(method, 'DELETE');
        final result = await _enqueue(() => _deleteConversation(segments[1]));
        await _writeJson(response, HttpStatus.ok, {'ok': true, 'data': result});
        return;
      }

      if (segments.length == 3 &&
          segments[0] == 'conversations' &&
          segments[2] == 'messages') {
        _expectMethod(method, 'GET');
        final result = await _enqueue(() => _listMessages(segments[1]));
        await _writeJson(response, HttpStatus.ok, {'ok': true, 'data': result});
        return;
      }

      if (segments.length == 2 &&
          segments[0] == 'messages' &&
          segments[1] == 'send') {
        _expectMethod(method, 'POST');
        final body = await _readJsonObject(request);
        final result = await _enqueue(
          () => _sendMessage(
            conversationId: _optionalString(body['conversationId']),
            title: _optionalString(body['title']),
            assistantId: _optionalString(body['assistantId']),
            providerKey: _optionalString(body['providerKey']),
            modelId: _optionalString(body['modelId']),
            text: _optionalString(body['text']) ?? '',
            imagePaths: _stringList(body['imagePaths']),
            documents: _documentList(body['documents']),
          ),
        );
        await _writeJson(response, HttpStatus.ok, {'ok': true, 'data': result});
        return;
      }

      throw _ApiBridgeException('not_found', statusCode: HttpStatus.notFound);
    } on _ApiBridgeException catch (error) {
      await _writeJson(response, error.statusCode, _error(error.code));
    } catch (error, stackTrace) {
      FlutterLogger.log(
        '[ApiBridge] Request failed: $error\n$stackTrace',
        tag: 'ApiBridge',
      );
      await _writeJson(
        response,
        HttpStatus.internalServerError,
        _error('internal_error', details: error.toString()),
      );
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _serial = _serial.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Map<String, dynamic> _status() {
    return {
      'started': _started,
      'baseUrl': 'http://$host:$port/api/bridge/v1',
      'currentAssistantId': _assistantProvider.currentAssistantId,
      'currentConversationId': _chatController?.currentConversation?.id,
      'currentModel': _currentModelState(),
      'reasoning': _reasoningState(),
    };
  }

  List<Map<String, dynamic>> _listAssistants() {
    return _assistantProvider.assistants
        .map(
          (assistant) => _assistantToJson(
            assistant,
            selected: assistant.id == _assistantProvider.currentAssistantId,
          ),
        )
        .toList(growable: false);
  }

  Map<String, dynamic> _currentAssistantState() {
    final assistant = _assistantProvider.currentAssistant;
    if (assistant == null) {
      throw _ApiBridgeException(
        'assistant_not_found',
        statusCode: HttpStatus.notFound,
      );
    }
    return _assistantToJson(assistant, selected: true);
  }

  Future<Map<String, dynamic>> _selectAssistant(String assistantId) async {
    final assistant = _assistantProvider.getById(assistantId);
    if (assistant == null) {
      throw _ApiBridgeException(
        'assistant_not_found',
        statusCode: HttpStatus.notFound,
      );
    }
    await _assistantProvider.setCurrentAssistant(assistantId);
    return _assistantToJson(assistant, selected: true);
  }

  List<Map<String, dynamic>> _listModels() {
    final settings = _settingsProvider;
    return buildKelivoApiBridgeModelCatalog(
      providerConfigs: settings.providerConfigs,
      currentProviderKey: settings.currentModelProvider,
      currentModelId: settings.currentModelId,
    ).map((item) => item.toJson()).toList(growable: false);
  }

  Map<String, dynamic> _currentModelState() {
    final settings = _settingsProvider;
    final assistant = _assistantProvider.currentAssistant;
    return {
      'globalProviderKey': settings.currentModelProvider,
      'globalModelId': settings.currentModelId,
      'effectiveProviderKey':
          assistant?.chatModelProvider ?? settings.currentModelProvider,
      'effectiveModelId': assistant?.chatModelId ?? settings.currentModelId,
      'assistantId': assistant?.id,
      'assistantUsesDedicatedModel':
          assistant?.chatModelProvider != null &&
          assistant?.chatModelId != null,
    };
  }

  Future<Map<String, dynamic>> _selectModel(
    String providerKey,
    String modelId,
  ) async {
    final exists = _listModels().any(
      (item) =>
          item['providerKey'] == providerKey && item['modelId'] == modelId,
    );
    if (!exists) {
      throw _ApiBridgeException(
        'model_not_found',
        statusCode: HttpStatus.notFound,
      );
    }
    await _settingsProvider.setCurrentModel(providerKey, modelId);
    return _currentModelState();
  }

  Map<String, dynamic> _reasoningState() {
    final assistant = _assistantProvider.currentAssistant;
    return {
      'globalThinkingBudget': _settingsProvider.thinkingBudget,
      'assistantThinkingBudget': assistant?.thinkingBudget,
      'effectiveThinkingBudget':
          assistant?.thinkingBudget ?? _settingsProvider.thinkingBudget,
    };
  }

  Future<Map<String, dynamic>> _setThinkingBudget(dynamic rawBudget) async {
    int? budget;
    if (rawBudget != null) {
      if (rawBudget is! num) {
        throw _ApiBridgeException(
          'invalid_thinking_budget',
          statusCode: HttpStatus.badRequest,
        );
      }
      budget = rawBudget.toInt();
    }
    await _settingsProvider.setThinkingBudget(budget);
    return _reasoningState();
  }

  List<Map<String, dynamic>> _listConversations() {
    return _chatServiceOrThrow
        .getAllConversations()
        .map(_conversationToJson)
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _createConversation({
    String? title,
    String? assistantId,
  }) async {
    if (assistantId != null) {
      final assistant = _assistantProvider.getById(assistantId);
      if (assistant == null) {
        throw _ApiBridgeException(
          'assistant_not_found',
          statusCode: HttpStatus.notFound,
        );
      }
      await _assistantProvider.setCurrentAssistant(assistantId);
    }

    await _viewModelOrThrow.createNewConversation();
    final conversation = _chatControllerOrThrow.currentConversation;
    if (conversation == null) {
      throw _ApiBridgeException('conversation_create_failed');
    }
    if (title != null && title.trim().isNotEmpty) {
      await _chatServiceOrThrow.renameConversation(
        conversation.id,
        title.trim(),
      );
      _chatControllerOrThrow.updateCurrentConversation(
        _chatServiceOrThrow.getConversation(conversation.id),
      );
    }
    final current = _chatServiceOrThrow.getConversation(conversation.id);
    if (current == null) {
      throw _ApiBridgeException('conversation_create_failed');
    }
    return _conversationToJson(current);
  }

  Future<Map<String, dynamic>> _deleteConversation(
    String conversationId,
  ) async {
    final conversation = _chatServiceOrThrow.getConversation(conversationId);
    if (conversation == null) {
      throw _ApiBridgeException(
        'conversation_not_found',
        statusCode: HttpStatus.notFound,
      );
    }
    if (_chatControllerOrThrow.currentConversation?.id == conversationId) {
      await _viewModelOrThrow.cancelStreaming();
      _chatControllerOrThrow.clearCurrentConversation();
    }
    await _chatServiceOrThrow.deleteConversation(conversationId);
    return {'deleted': true, 'conversationId': conversationId};
  }

  Future<List<Map<String, dynamic>>> _listMessages(
    String conversationId,
  ) async {
    final conversation = _chatServiceOrThrow.getConversation(conversationId);
    if (conversation == null) {
      throw _ApiBridgeException(
        'conversation_not_found',
        statusCode: HttpStatus.notFound,
      );
    }
    return _chatServiceOrThrow
        .getMessages(conversationId)
        .map(_messageToJson)
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> _sendMessage({
    String? conversationId,
    String? title,
    String? assistantId,
    String? providerKey,
    String? modelId,
    required String text,
    required List<String> imagePaths,
    required List<DocumentAttachment> documents,
  }) async {
    if ((providerKey == null) != (modelId == null)) {
      throw _ApiBridgeException(
        'model_selection_incomplete',
        statusCode: HttpStatus.badRequest,
      );
    }
    if (providerKey != null && modelId != null) {
      await _selectModel(providerKey, modelId);
    }

    if (conversationId == null || conversationId.trim().isEmpty) {
      final created = await _createConversation(
        title: title,
        assistantId: assistantId,
      );
      conversationId = (created['id'] ?? '').toString();
    }

    final resolvedConversationId = conversationId.trim();
    final conversation = _chatServiceOrThrow.getConversation(
      resolvedConversationId,
    );
    if (conversation == null) {
      throw _ApiBridgeException(
        'conversation_not_found',
        statusCode: HttpStatus.notFound,
      );
    }

    await _viewModelOrThrow.switchConversation(resolvedConversationId);

    final effectiveAssistantId = assistantId ?? conversation.assistantId;
    if (effectiveAssistantId != null && effectiveAssistantId.isNotEmpty) {
      final assistant = _assistantProvider.getById(effectiveAssistantId);
      if (assistant == null) {
        throw _ApiBridgeException(
          'assistant_not_found',
          statusCode: HttpStatus.notFound,
        );
      }
      await _assistantProvider.setCurrentAssistant(effectiveAssistantId);
      if (conversation.assistantId != effectiveAssistantId) {
        await _chatServiceOrThrow.moveConversationToAssistant(
          conversationId: resolvedConversationId,
          assistantId: effectiveAssistantId,
        );
      }
    }

    final beforeIds = _chatServiceOrThrow
        .getMessages(resolvedConversationId)
        .map((message) => message.id)
        .toSet();
    _lastError = null;
    _lastWarning = null;

    final success = await _viewModelOrThrow.sendMessage(
      ChatInputData(text: text, imagePaths: imagePaths, documents: documents),
    );
    if (!success) {
      throw _ApiBridgeException(
        _lastWarning ?? _lastError ?? 'send_failed',
        statusCode: HttpStatus.badRequest,
      );
    }

    final assistantMessage = await _waitForAssistantResponse(
      resolvedConversationId,
      beforeIds,
      timeout: _sendTimeout,
    );
    return {
      'conversation': _conversationToJson(
        _chatServiceOrThrow.getConversation(resolvedConversationId) ??
            conversation,
      ),
      'message': _messageToJson(assistantMessage),
      'currentModel': _currentModelState(),
      'reasoning': _reasoningState(),
    };
  }

  Future<ChatMessage> _waitForAssistantResponse(
    String conversationId,
    Set<String> beforeIds, {
    required Duration timeout,
  }) async {
    final endAt = DateTime.now().add(timeout);
    String? assistantMessageId;

    while (DateTime.now().isBefore(endAt)) {
      final messages = _chatServiceOrThrow.getMessages(conversationId);
      final newAssistants = messages
          .where(
            (message) =>
                message.role == 'assistant' && !beforeIds.contains(message.id),
          )
          .toList(growable: false);
      if (newAssistants.isNotEmpty) {
        newAssistants.sort(
          (left, right) => left.timestamp.compareTo(right.timestamp),
        );
        assistantMessageId ??= newAssistants.last.id;
        final current = messages.firstWhere(
          (message) => message.id == assistantMessageId,
          orElse: () => newAssistants.last,
        );
        if (!current.isStreaming) {
          return current;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    throw _ApiBridgeException(
      'send_timeout',
      statusCode: HttpStatus.gatewayTimeout,
    );
  }

  Map<String, dynamic> _assistantToJson(
    Assistant assistant, {
    required bool selected,
  }) {
    return {
      'id': assistant.id,
      'name': assistant.name,
      'selected': selected,
      'deletable': assistant.deletable,
      'chatModelProvider': assistant.chatModelProvider,
      'chatModelId': assistant.chatModelId,
      'usesDedicatedModel':
          assistant.chatModelProvider != null && assistant.chatModelId != null,
      'temperature': assistant.temperature,
      'topP': assistant.topP,
      'thinkingBudget': assistant.thinkingBudget,
      'streamOutput': assistant.streamOutput,
      'enableMemory': assistant.enableMemory,
      'enableRecentChatsReference': assistant.enableRecentChatsReference,
      'presetMessageCount': assistant.presetMessages.length,
    };
  }

  Map<String, dynamic> _conversationToJson(Conversation conversation) {
    final assistant = conversation.assistantId == null
        ? null
        : _assistantProvider.getById(conversation.assistantId!);
    return {
      ...conversation.toJson(),
      'messageCount': conversation.messageIds.length,
      'assistantName': assistant?.name,
      'current':
          _chatControllerOrThrow.currentConversation?.id == conversation.id,
    };
  }

  Map<String, dynamic> _messageToJson(ChatMessage message) {
    final data = Map<String, dynamic>.from(message.toJson());
    if (message.role == 'user') {
      final parsed = _messageBuilderServiceOrThrow.parseInputFromRaw(
        message.content,
      );
      data['parsed'] = {
        'text': parsed.text,
        'imagePaths': parsed.imagePaths,
        'documents': parsed.documents
            .map(
              (item) => {
                'path': item.path,
                'fileName': item.fileName,
                'mime': item.mime,
              },
            )
            .toList(growable: false),
      };
    }
    if (message.role == 'assistant') {
      data['toolEvents'] = _chatServiceOrThrow.getToolEvents(message.id);
      data['geminiThoughtSignature'] = _chatServiceOrThrow
          .getGeminiThoughtSignature(message.id);
    }
    return data;
  }

  void _scheduleInlineImageSanitize(
    String messageId, {
    required String latestContent,
    required bool immediate,
  }) {
    if (latestContent.isEmpty ||
        !latestContent.contains('data:image') ||
        !latestContent.contains('base64,')) {
      return;
    }
    _streamControllerOrThrow.scheduleInlineImageSanitize(
      messageId,
      latestContent: latestContent,
      immediate: immediate,
      onSanitized: (id, sanitizedContent) async {
        await _chatServiceOrThrow.updateMessage(id, content: sanitizedContent);
        final index = _chatControllerOrThrow.messages.indexWhere(
          (message) => message.id == id,
        );
        if (index != -1) {
          _chatControllerOrThrow.messages[index] = _chatControllerOrThrow
              .messages[index]
              .copyWith(content: sanitizedContent);
        }
      },
    );
  }

  static Future<Map<String, dynamic>> _readJsonObject(
    HttpRequest request,
  ) async {
    final content = await utf8.decoder.bind(request).join();
    if (content.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw _ApiBridgeException(
        'invalid_json_body',
        statusCode: HttpStatus.badRequest,
      );
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  static void _expectMethod(String actual, String expected) {
    if (actual != expected) {
      throw _ApiBridgeException(
        'method_not_allowed',
        statusCode: HttpStatus.methodNotAllowed,
      );
    }
  }

  static String _requireString(Map<String, dynamic> body, String key) {
    final value = _optionalString(body[key]);
    if (value == null || value.isEmpty) {
      throw _ApiBridgeException(
        'missing_$key',
        statusCode: HttpStatus.badRequest,
      );
    }
    return value;
  }

  static String? _optionalString(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const <String>[];
    return raw
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static List<DocumentAttachment> _documentList(dynamic raw) {
    if (raw is! List) return const <DocumentAttachment>[];
    final documents = <DocumentAttachment>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final data = item.map((key, value) => MapEntry(key.toString(), value));
      final path = _optionalString(data['path']);
      final fileName = _optionalString(data['fileName'] ?? data['name']);
      final mime = _optionalString(data['mime']);
      if (path == null || fileName == null || mime == null) continue;
      documents.add(
        DocumentAttachment(path: path, fileName: fileName, mime: mime),
      );
    }
    return documents;
  }

  static Map<String, dynamic> _error(String code, {String? details}) {
    return {
      'ok': false,
      'error': {
        'code': code,
        if (details != null && details.isNotEmpty) 'details': details,
      },
    };
  }

  static Future<void> _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> payload,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(payload));
    await response.close();
  }

  static void _setCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set(
      'Access-Control-Allow-Methods',
      'GET, POST, DELETE, OPTIONS',
    );
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
  }

  String _titleForLocale(BuildContext context) {
    return AppLocalizations.of(context)!.titleForLocale;
  }

  AssistantProvider get _assistantProvider {
    final context = _context;
    if (context == null) throw _ApiBridgeException('bridge_not_started');
    return context.read<AssistantProvider>();
  }

  SettingsProvider get _settingsProvider {
    final context = _context;
    if (context == null) throw _ApiBridgeException('bridge_not_started');
    return context.read<SettingsProvider>();
  }

  ChatService get _chatServiceOrThrow {
    final value = _chatService;
    if (value == null) throw _ApiBridgeException('bridge_not_started');
    return value;
  }

  ChatController get _chatControllerOrThrow {
    final value = _chatController;
    if (value == null) throw _ApiBridgeException('bridge_not_started');
    return value;
  }

  stream_ctrl.StreamController get _streamControllerOrThrow {
    final value = _streamController;
    if (value == null) throw _ApiBridgeException('bridge_not_started');
    return value;
  }

  MessageBuilderService get _messageBuilderServiceOrThrow {
    final value = _messageBuilderService;
    if (value == null) throw _ApiBridgeException('bridge_not_started');
    return value;
  }

  HomeViewModel get _viewModelOrThrow {
    final value = _viewModel;
    if (value == null) throw _ApiBridgeException('bridge_not_started');
    return value;
  }
}

class _ApiBridgeException implements Exception {
  _ApiBridgeException(this.code, {this.statusCode = HttpStatus.badRequest});

  final String code;
  final int statusCode;
}
