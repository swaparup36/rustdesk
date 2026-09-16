import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _browserMessageChannel = MethodChannel('webview_message/client_channel');
const _toolbarBackground = Color(0xff202124);

bool runDesktopWebViewTitleBarWidget(List<String> args) {
  return runWebViewTitleBarWidget(
    args,
    backgroundColor: _toolbarBackground,
    builder: (context) => const _BrowserTitleBar(),
  );
}

class _BrowserTitleBar extends StatefulWidget {
  const _BrowserTitleBar();

  @override
  State<_BrowserTitleBar> createState() => _BrowserTitleBarState();
}

class _BrowserTitleBarState extends State<_BrowserTitleBar> {
  final _addressController = TextEditingController();
  final _addressFocusNode = FocusNode();
  List<Map<dynamic, dynamic>> _tabs = [];
  int? _activeId;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _browserMessageChannel.setMethodCallHandler((call) async {
      if (!mounted) return;
      switch (call.method) {
        case 'browserState':
          final state = call.arguments as Map<dynamic, dynamic>;
          final url = state['url'] as String? ?? '';
          if (!_addressFocusNode.hasFocus) {
            _addressController.text = url;
          }
          setState(() {
            _tabs =
                (state['tabs'] as List<dynamic>).cast<Map<dynamic, dynamic>>();
            _activeId = state['activeId'] as int?;
            _canGoBack = state['canGoBack'] as bool? ?? false;
            _canGoForward = state['canGoForward'] as bool? ?? false;
            _loading = false;
          });
          break;
        case 'onNavigationStarted':
          setState(() => _loading = true);
          break;
        case 'onNavigationCompleted':
          setState(() => _loading = false);
          break;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _browserMessageChannel.invokeMethod(
          'requestBrowserState', const <String, Object>{});
    });
  }

  @override
  void dispose() {
    _browserMessageChannel.setMethodCallHandler(null);
    _addressController.dispose();
    _addressFocusNode.dispose();
    super.dispose();
  }

  void _navigate() {
    final url = _addressController.text.trim();
    if (url.isNotEmpty) {
      _browserMessageChannel.invokeMethod('navigate', url);
      _addressFocusNode.unfocus();
    }
  }

  Widget _button(String tooltip, IconData icon, VoidCallback? action) {
    return IconButton(
      tooltip: tooltip,
      onPressed: action,
      icon: Icon(icon, size: 18),
      color: const Color(0xffe3e4e8),
      disabledColor: const Color(0xff777982),
      splashRadius: 18,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 38,
          child: Row(
            children: [
              const SizedBox(width: 8),
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _tabs.length,
                  itemBuilder: (context, index) {
                    final tab = _tabs[index];
                    final id = tab['id'] as int;
                    final selected = id == _activeId;
                    return Container(
                      width: 190,
                      margin: const EdgeInsets.fromLTRB(4, 5, 0, 0),
                      decoration: BoxDecoration(
                        color: selected
                            ? const Color(0xff37383e)
                            : const Color(0xff292a2f),
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(9)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: () => _browserMessageChannel.invokeMethod(
                                  'selectTab', id),
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                child: Text(
                                  tab['title'] as String? ?? 'New tab',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: () => _browserMessageChannel.invokeMethod(
                                'closeTab', id),
                            child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(Icons.close,
                                  color: Color(0xffc2c4ca), size: 15),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              _button('New tab', Icons.add,
                  () => _browserMessageChannel.invokeMethod(
                      'newTab', const <String, Object>{})),
              _button('Close browser', Icons.close,
                  () => _browserMessageChannel.invokeMethod(
                      'onClosePressed', const <String, Object>{})),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              _button(
                  'Back',
                  Icons.arrow_back,
                  _canGoBack
                      ? () =>
                          _browserMessageChannel.invokeMethod(
                              'onBackPressed', const <String, Object>{})
                      : null),
              _button(
                  'Forward',
                  Icons.arrow_forward,
                  _canGoForward
                      ? () => _browserMessageChannel
                          .invokeMethod(
                              'onForwardPressed', const <String, Object>{})
                      : null),
              _button(
                  _loading ? 'Stop' : 'Reload',
                  _loading ? Icons.close : Icons.refresh,
                  () => _browserMessageChannel.invokeMethod(
                      _loading ? 'onStopPressed' : 'onRefreshPressed',
                      const <String, Object>{})),
              Expanded(
                child: Container(
                  height: 33,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 13),
                  decoration: BoxDecoration(
                    color: const Color(0xff33343a),
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.public,
                          color: Color(0xffc0c2ca), size: 17),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _addressController,
                          focusNode: _addressFocusNode,
                          onSubmitted: (_) => _navigate(),
                          style: const TextStyle(
                              color: Color(0xfff4f4f6), fontSize: 13),
                          cursorColor: const Color(0xfff4f4f6),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            hintText: 'Search or enter address',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
