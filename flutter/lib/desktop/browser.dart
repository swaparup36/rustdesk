import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/platform_model.dart';

const _browserMessageChannel = MethodChannel('webview_message/client_channel');
const _newTabAsset = 'assets/browser_new_tab.html';
const _connectAsset = 'assets/browser_connect.html';

Webview? _browserWindow;
Future<bool>? _browserStartup;
_BrowserState? _browserState;

Future<bool> showDesktopBrowser({
  required bool Function(String url) onUrlRequest,
  bool openConnectTab = false,
}) async {
  if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
    return false;
  }

  final startup = _browserStartup;
  if (startup != null) {
    if (!await startup) return false;
  } else if (_browserWindow == null) {
    final result = _createBrowser(onUrlRequest);
    _browserStartup = result;
    try {
      if (!await result) return false;
    } catch (error, stackTrace) {
      debugPrint('Failed to start the desktop browser: $error');
      debugPrintStack(stackTrace: stackTrace);
      return false;
    } finally {
      if (identical(_browserStartup, result)) _browserStartup = null;
    }
  }

  if (openConnectTab) {
    await _browserState?.openConnectTab();
  }
  final window = _browserWindow;
  if (window == null) return false;
  await window.setWebviewWindowVisibility(true);
  await window.bringToForeground();
  return true;
}

Future<bool> _createBrowser(bool Function(String url) onUrlRequest) async {
  if (!await WebviewWindow.isWebviewAvailable()) {
    debugPrint('The WebView runtime is not available.');
    return false;
  }

  final directory = await getApplicationSupportDirectory();
  Future<String> installPage(String asset, String name) async {
    final file = File(p.join(directory.path, name));
    await file.writeAsString(await rootBundle.loadString(asset));
    return file.uri.toString();
  }

  final newTabUrl =
      await installPage(_newTabAsset, 'techno_browser_new_tab.html');
  final connectUrl =
      await installPage(_connectAsset, 'techno_browser_connect.html');
  final webview = await WebviewWindow.create(
    configuration: CreateConfiguration(
      title: 'techno-browser',
      windowWidth: 1280,
      windowHeight: 800,
      titleBarHeight: 88,
      titleBarTopPadding: Platform.isMacOS ? 24 : 0,
      userDataFolderWindows: p.join(directory.path, 'techno-browser'),
    ),
  );
  final state = _BrowserState(webview, newTabUrl, connectUrl, onUrlRequest);
  _browserWindow = webview;
  _browserState = state;
  _browserMessageChannel.setMethodCallHandler(state.handleToolbarCall);
  webview.setOnUrlRequestCallback(state.handleUrlRequest);
  webview.addOnWebMessageReceivedCallback(state.handleWebMessage);
  webview.onClose.whenComplete(() {
    if (identical(_browserWindow, webview)) {
      _browserWindow = null;
      _browserState = null;
      _browserMessageChannel.setMethodCallHandler(null);
    }
  });
  await state.newTab();
  return true;
}

class _BrowserTab {
  _BrowserTab(this.id, this.title, this.displayUrl, this.url) : history = [url];

  final int id;
  String title;
  String displayUrl;
  String url;
  final List<String> history;
  int historyIndex = 0;
}

class _BrowserState {
  _BrowserState(
      this.webview, this.newTabUrl, this.connectUrl, this.onUrlRequest);

  final Webview webview;
  final String newTabUrl;
  final String connectUrl;
  final bool Function(String url) onUrlRequest;
  final List<_BrowserTab> tabs = [];
  int nextTabId = 1;
  int? activeTabId;

  _BrowserTab? get activeTab {
    for (final tab in tabs) {
      if (tab.id == activeTabId) return tab;
    }
    return null;
  }

  Future<void> broadcastState() async {
    final active = activeTab;
    await _browserMessageChannel.invokeMethod('browserState', {
      'tabs': tabs.map((tab) => {'id': tab.id, 'title': tab.title}).toList(),
      'activeId': activeTabId,
      'url': active?.displayUrl ?? '',
      'canGoBack': active != null && active.historyIndex > 0,
      'canGoForward':
          active != null && active.historyIndex < active.history.length - 1,
    });
  }

  Future<void> _load(_BrowserTab tab) async {
    webview.launch(tab.url, triggerOnUrlRequestEvent: false);
    await broadcastState();
  }

  Future<void> newTab() async {
    final tab =
        _BrowserTab(nextTabId++, 'New tab', 'techno://newtab', newTabUrl);
    tabs.add(tab);
    activeTabId = tab.id;
    await _load(tab);
  }

  Future<void> openConnectTab() async {
    var localId = '';
    var lastRemoteId = '';
    var recentPeers = '[]';
    try {
      localId = await bind.mainGetMyId();
      lastRemoteId = await bind.mainGetLastRemoteId();
      final peers = jsonDecode(await bind.mainLoadRecentPeersForAb(filter: '[]'));
      if (peers is List) {
        recentPeers = jsonEncode(peers.take(8).map((peer) {
          if (peer is Map) {
            return {
              'id': peer['id']?.toString() ?? '',
              'name': peer['alias']?.toString().isNotEmpty == true
                  ? peer['alias'].toString()
                  : peer['hostname']?.toString() ?? '',
            };
          }
          return <String, String>{};
        }).toList());
      }
    } catch (error) {
      debugPrint('Could not load connection details: $error');
    }
    final url = Uri.parse(connectUrl).replace(queryParameters: {
      'id': localId,
      'last': lastRemoteId,
      'recent': recentPeers,
    }).toString();
    final tab =
        _BrowserTab(nextTabId++, 'Connect', 'techno://connect', url);
    tabs.add(tab);
    activeTabId = tab.id;
    await _load(tab);
  }

  Future<void> selectTab(int id) async {
    for (final tab in tabs) {
      if (tab.id == id) {
        activeTabId = id;
        await _load(tab);
        return;
      }
    }
  }

  Future<void> closeTab(int id) async {
    final index = tabs.indexWhere((tab) => tab.id == id);
    if (index < 0) return;
    tabs.removeAt(index);
    if (tabs.isEmpty) {
      await newTab();
    } else if (activeTabId == id) {
      final next = tabs[index < tabs.length ? index : tabs.length - 1];
      activeTabId = next.id;
      await _load(next);
    } else {
      await broadcastState();
    }
  }

  Future<void> navigate(String input) async {
    var url = input.trim();
    if (url.isEmpty) return;
    if (url.toLowerCase().startsWith('techno://')) {
      onUrlRequest(url);
      return;
    }
    if (!url.contains('://')) {
      url = url.contains('.') && !url.contains(' ')
          ? 'https://$url'
          : 'https://www.google.com/search?q=${Uri.encodeQueryComponent(url)}';
    }
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
    _recordNavigation(url);
    final tab = activeTab;
    if (tab != null) await _load(tab);
  }

  void _recordNavigation(String url) {
    final tab = activeTab;
    if (tab == null || tab.url == url) return;
    tab.history.removeRange(tab.historyIndex + 1, tab.history.length);
    tab.history.add(url);
    tab.historyIndex = tab.history.length - 1;
    tab.url = url;
    tab.displayUrl = url;
    tab.title = Uri.tryParse(url)?.host ?? 'Page';
    broadcastState();
  }

  bool handleUrlRequest(String url) {
    if (!onUrlRequest(url)) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      _recordNavigation(url);
      return true;
    }
    return url.startsWith(newTabUrl) || url.startsWith(connectUrl);
  }

  void handleWebMessage(String message) {
    if (activeTab?.url.startsWith(connectUrl) != true) return;
    try {
      final data = jsonDecode(message);
      if (data is! Map || data['type'] != 'connect') return;
      final id = data['id'];
      if (id is! String || id.trim().isEmpty || id.length > 256) return;
      onUrlRequest('techno://connect/${Uri.encodeComponent(id.trim())}');
    } on FormatException {
      debugPrint('Ignored an invalid browser dashboard message.');
    }
  }

  Future<void> _moveHistory(int offset) async {
    final tab = activeTab;
    if (tab == null) return;
    final next = tab.historyIndex + offset;
    if (next < 0 || next >= tab.history.length) return;
    tab.historyIndex = next;
    tab.url = tab.history[next];
    tab.displayUrl = tab.url == newTabUrl
        ? 'techno://newtab'
        : tab.url.startsWith(connectUrl)
            ? 'techno://connect'
            : tab.url;
    tab.title = tab.url == newTabUrl
        ? 'New tab'
        : tab.url.startsWith(connectUrl)
            ? 'Connect'
            : Uri.tryParse(tab.url)?.host ?? 'Page';
    await _load(tab);
  }

  Future<void> handleToolbarCall(MethodCall call) async {
    switch (call.method) {
      case 'requestBrowserState':
        await broadcastState();
        break;
      case 'newTab':
        await newTab();
        break;
      case 'selectTab':
        if (call.arguments is int) await selectTab(call.arguments as int);
        break;
      case 'closeTab':
        if (call.arguments is int) await closeTab(call.arguments as int);
        break;
      case 'navigate':
        if (call.arguments is String) await navigate(call.arguments as String);
        break;
      case 'onBackPressed':
        await _moveHistory(-1);
        break;
      case 'onForwardPressed':
        await _moveHistory(1);
        break;
      case 'onRefreshPressed':
        await webview.reload();
        break;
      case 'onStopPressed':
        await webview.stop();
        break;
      case 'onClosePressed':
        webview.close();
        break;
    }
  }
}
