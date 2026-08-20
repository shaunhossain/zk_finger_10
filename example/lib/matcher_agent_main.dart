import 'package:flutter/material.dart';

import 'matcher_agent.dart';

/// Entry point for the **matcher agent** (Option A backend-side matching).
///
/// Run on any Android device with this plugin installed (no fingerprint
/// sensor needed for matching - `ZKFingerService.verify()` is pure math):
///
///   cd example
///   flutter run -t lib/matcher_agent_main.dart -d <android-device-id>
///
/// Your backend then calls this device:
///
///   GET  http://<device-ip>:8787/health
///   POST http://<device-ip>:8787/verify    {template1, template2}
///   POST http://<device-ip>:8787/identify  {template, candidates}
///
/// Set AGENT_TOKEN in main() if your network is shared.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MatcherAgentApp());
}

class MatcherAgentApp extends StatelessWidget {
  const MatcherAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    final server = MatcherAgentServer(
      port: 8787,
      // token: 'change-me',        // enable to require x-agent-token header
      matchThreshold: 70,
    );

    // Start the HTTP server alongside a minimal UI.
    // ignore: unawaited_futures
    server.start();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black87,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.dns, color: Colors.tealAccent, size: 64),
              SizedBox(height: 16),
              Text('ZK Matcher Agent',
                  style: TextStyle(color: Colors.white, fontSize: 22)),
              SizedBox(height: 8),
              Text('listening on :8787',
                  style: TextStyle(color: Colors.white54)),
              SizedBox(height: 24),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'Backend matching service is running.\n'
                  'Set MATCHER_URL=http://<this-device-ip>:8787 on your backend.\n'
                  'Keep this device powered and on the same network.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white30, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}