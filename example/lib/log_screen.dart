import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'device_log.dart';

/// Live view of DeviceLog.buffer. Auto-refreshes every 500ms.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final ScrollController _scroll = ScrollController();
  bool _follow = true;
  int _lastLen = -1;

  @override
  void initState() {
    super.initState();
    _tick();
  }

  void _tick() {
    if (!mounted) return;
    if (DeviceLog.buffer.length != _lastLen) {
      _lastLen = DeviceLog.buffer.length;
      setState(() {});
      if (_follow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    }
    Future<void>.delayed(const Duration(milliseconds: 500), _tick);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<String> lines = DeviceLog.buffer;
    return Scaffold(
      backgroundColor: const Color(0xFF101418),
      appBar: AppBar(
        title: Text('Device Log (${lines.length})'),
        actions: <Widget>[
          IconButton(
            tooltip: DeviceLog.fullTemplate ? 'Full base64: ON' : 'Full base64: OFF',
            icon: Icon(DeviceLog.fullTemplate
                ? Icons.unfold_less
                : Icons.unfold_more),
            onPressed: () =>
                setState(() => DeviceLog.fullTemplate = !DeviceLog.fullTemplate),
          ),
          IconButton(
            tooltip: DeviceLog.jsonMode ? 'JSON: ON' : 'JSON: OFF',
            icon: Icon(DeviceLog.jsonMode
                ? Icons.data_object
                : Icons.data_object_outlined),
            onPressed: () =>
                setState(() => DeviceLog.jsonMode = !DeviceLog.jsonMode),
          ),
          IconButton(
            tooltip: _follow ? 'Auto-scroll: ON' : 'Auto-scroll: OFF',
            icon: Icon(_follow ? Icons.vertical_align_bottom : Icons.pause),
            onPressed: () => setState(() => _follow = !_follow),
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: DeviceLog.dump()));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Log copied')),
              );
            },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(DeviceLog.clear),
          ),
        ],
      ),
      body: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(8),
        itemCount: lines.length,
        itemBuilder: (BuildContext c, int i) {
          final String line = lines[i];
          Color color = const Color(0xFFB0BEC5);
          if (line.contains('[STATUS]')) color = const Color(0xFF80CBC4);
          if (line.contains('[IMAGE]')) color = const Color(0xFF90CAF9);
          if (line.contains('[CALL]')) color = const Color(0xFFCE93D8);
          if (line.contains('[RAW-STATUS]')) color = const Color(0xFF616E7C);
          if (line.contains('[JSON]')) color = const Color(0xFFFFCC80);
          if (line.contains('[ERROR]')) color = const Color(0xFFEF9A9A);
          return SelectableText(
            line,
            style: TextStyle(
                color: color, fontFamily: 'monospace', fontSize: 11, height: 1.3),
          );
        },
      ),
    );
  }
}
