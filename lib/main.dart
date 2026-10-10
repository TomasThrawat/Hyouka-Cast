import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

const _port = 38741;
const _black = Color(0xFF000000);
const _white = Color(0xFFFFFFFF);
const _muted = Color(0xFFBDBDBD);
const _border = Color(0xFF343434);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HyoukaCastApp());
}

class HyoukaCastApp extends StatelessWidget {
  const HyoukaCastApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Hyouka Cast',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: _black,
          canvasColor: _black,
          colorScheme: const ColorScheme.dark(
            primary: _white, onPrimary: _black,
            surface: _black, onSurface: _white,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: _black, foregroundColor: _white, elevation: 0,
          ),
          inputDecorationTheme: const InputDecorationTheme(
            filled: true,
            fillColor: _black,
            labelStyle: TextStyle(color: _muted),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: _border),
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: _white),
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
          ),
          textSelectionTheme: const TextSelectionThemeData(
            cursorColor: _white,
            selectionColor: Color(0x66777777),
            selectionHandleColor: _white,
          ),
        ),
        home: const CastHomePage(),
      );
}

enum _Mode { phone, tv }

class CastHomePage extends StatefulWidget {
  const CastHomePage({super.key});

  @override
  State<CastHomePage> createState() => _CastHomePageState();
}

class _CastHomePageState extends State<CastHomePage> {
  final _address = TextEditingController();
  final _pinInput = TextEditingController();
  final _renderer = RTCVideoRenderer();
  final List<RTCIceCandidate> _pendingIce = [];
  HttpServer? _http;
  StreamSubscription<HttpRequest>? _httpSub;
  StreamSubscription<dynamic>? _socketSub;
  WebSocket? _socket;
  RTCPeerConnection? _peer;
  MediaStream? _screen;
  _Mode? _mode;
  bool _rendererReady = false;
  bool _receiverRunning = false;
  bool _sharing = false;
  bool _remoteDescriptionSet = false;
  String _pin = '';
  String _status = 'Ready';
  List<String> _addresses = [];

  _Mode _effectiveMode(BuildContext context) =>
      _mode ?? (MediaQuery.sizeOf(context).width >= 800 ? _Mode.tv : _Mode.phone);

  @override
  void dispose() {
    _address.dispose();
    _pinInput.dispose();
    _httpSub?.cancel();
    _http?.close(force: true);
    _socketSub?.cancel();
    _socket?.close();
    _peer?.close();
    _screen?.dispose();
    if (_rendererReady) _renderer.dispose();
    super.dispose();
  }

  Future<void> _initRenderer() async {
    if (_rendererReady) return;
    await _renderer.initialize();
    _rendererReady = true;
  }

  bool _private172(String value) {
    final m = RegExp(r'^172\.(\d+)\.').firstMatch(value);
    final n = int.tryParse(m?.group(1) ?? '');
    return n != null && n >= 16 && n <= 31;
  }

  Future<List<String>> _getLanAddresses() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false, type: InternetAddressType.IPv4,
    );
    final found = <String>{};
    for (final i in interfaces) {
      for (final a in i.addresses) {
        final s = a.address;
        if (s.startsWith('192.168.') || s.startsWith('10.') || _private172(s)) found.add(s);
      }
    }
    return found.toList()..sort();
  }

  Future<void> _startReceiver() async {
    if (_receiverRunning) return;
    setState(() => _status = 'Starting local Wi-Fi receiver…');
    try {
      final addresses = await _getLanAddresses();
      final pin = (100000 + Random.secure().nextInt(900000)).toString();
      final server = await HttpServer.bind(InternetAddress.anyIPv4, _port, shared: true);
      _http = server;
      _pin = pin;
      _addresses = addresses;
      _httpSub = server.listen(_handleRequest);
      if (!mounted) return;
      setState(() {
        _receiverRunning = true;
        _status = addresses.isEmpty
            ? 'Receiver started, but no private IPv4 address was found.'
            : 'Ready. Connect your phone to this TV over the same Wi-Fi.';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Receiver failed: $e');
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (request.uri.path != '/signal' || !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (request.uri.queryParameters['pin'] != _pin || _pin.isEmpty) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }
    if (_socket != null) {
      request.response.statusCode = HttpStatus.conflict;
      await request.response.close();
      return;
    }
    try {
      final socket = await WebSocketTransformer.upgrade(request);
      _socket = socket;
      await _createPeer();
      _listen(socket);
      if (mounted) setState(() => _status = 'Phone paired. Waiting for the screen…');
    } catch (e) {
      if (mounted) setState(() => _status = 'Connection failed: $e');
      await _socket?.close();
      _socket = null;
    }
  }

  Future<void> _createPeer() async {
    await _peer?.close();
    _peer = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    _remoteDescriptionSet = false;
    _pendingIce.clear();
    _peer!.onIceCandidate = (candidate) {
      if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
        _send({'type': 'ice', 'candidate': candidate.toMap()});
      }
    };
    _peer!.onTrack = (event) async {
      if (event.streams.isEmpty) return;
      await _initRenderer();
      _renderer.srcObject = event.streams.first;
      if (mounted) setState(() => _status = 'Live screen received over Wi-Fi.');
    };
    _peer!.onConnectionState = (state) {
      if (!mounted) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        setState(() => _status = 'Connected over local Wi-Fi.');
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        setState(() => _status = 'Connection failed. Check Wi-Fi client isolation.');
      }
    };
  }

  void _listen(WebSocket socket) {
    _socketSub?.cancel();
    _socketSub = socket.listen(
      (data) => _handleSignal(data),
      onDone: () {
        if (mounted && identical(_socket, socket)) setState(() => _status = 'Phone disconnected.');
      },
      onError: (Object e) {
        if (mounted) setState(() => _status = 'Local socket error: $e');
      },
    );
  }

  Future<void> _handleSignal(dynamic data) async {
    try {
      final text = data is String ? data : utf8.decode(data as List<int>);
      final msg = jsonDecode(text) as Map<String, dynamic>;
      switch (msg['type']) {
        case 'offer':
          if (_peer == null) await _createPeer();
          final sdp = msg['sdp'] as String?;
          if (sdp == null) throw const FormatException('Missing offer SDP.');
          await _peer!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
          _remoteDescriptionSet = true;
          await _flushIce();
          final answer = await _peer!.createAnswer();
          await _peer!.setLocalDescription(answer);
          _send({'type': 'answer', 'sdp': answer.sdp});
          break;
        case 'answer':
          final sdp = msg['sdp'] as String?;
          if (sdp == null) throw const FormatException('Missing answer SDP.');
          await _peer!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
          _remoteDescriptionSet = true;
          await _flushIce();
          break;
        case 'ice':
          final raw = msg['candidate'];
          if (raw is Map) {
            final m = Map<String, dynamic>.from(raw);
            final c = RTCIceCandidate(
              m['candidate'] as String?,
              m['sdpMid'] as String?,
              (m['sdpMLineIndex'] as num?)?.toInt(),
            );
            if (_remoteDescriptionSet) {
              await _peer?.addCandidate(c);
            } else {
              _pendingIce.add(c);
            }
          }
          break;
        case 'error':
          if (mounted) setState(() => _status = (msg['message'] as String?) ?? 'Remote error.');
          break;
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Signaling error: $e');
    }
  }

  Future<void> _flushIce() async {
    final queued = List<RTCIceCandidate>.from(_pendingIce);
    _pendingIce.clear();
    for (final c in queued) {
      await _peer?.addCandidate(c);
    }
  }

  void _send(Map<String, dynamic> msg) {
    final ws = _socket;
    if (ws != null && ws.readyState == WebSocket.open) ws.add(jsonEncode(msg));
  }

  Future<void> _startSharing() async {
    final host = _address.text.trim();
    final pin = _pinInput.text.trim();
    final ip = InternetAddress.tryParse(host);
    if (ip == null || ip.type != InternetAddressType.IPv4) {
      setState(() => _status = 'Enter the TV IPv4 address, for example 192.168.1.50.');
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      setState(() => _status = 'Enter the six-digit code shown on the TV.');
      return;
    }
    setState(() => _status = 'Connecting to TV over Wi-Fi…');
    try {
      final uri = Uri(
        scheme: 'ws', host: host, port: _port, path: '/signal',
        queryParameters: {'pin': pin},
      );
      final ws = await WebSocket.connect(uri.toString()).timeout(const Duration(seconds: 10));
      _socket = ws;
      _listen(ws);
      await _createPeer();

      final consent = await Helper.requestCapturePermission(fullScreenOnly: true);
      if (!consent) throw StateError('Screen-capture permission was not granted.');

      final initialized = await FlutterBackground.initialize(
        androidConfig: const FlutterBackgroundAndroidConfig(
          notificationTitle: 'Hyouka Cast',
          notificationText: 'Sharing your screen on local Wi-Fi.',
          notificationImportance: AndroidNotificationImportance.normal,
          notificationIcon: AndroidResource(name: 'ic_stat_cast', defType: 'drawable'),
          enableWifiLock: true,
        ),
      );
      if (!initialized) throw StateError('Could not initialize the screen-sharing service.');
      final backgroundStarted = await FlutterBackground.enableBackgroundExecution();
      if (!backgroundStarted) throw StateError('Android did not start the foreground service.');

      _screen = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
      for (final track in _screen!.getVideoTracks()) {
        await _peer!.addTrack(track, _screen!);
      }
      final offer = await _peer!.createOffer();
      await _peer!.setLocalDescription(offer);
      _send({'type': 'offer', 'sdp': offer.sdp});
      if (mounted) setState(() {
        _sharing = true;
        _status = 'Sharing screen. Target is up to 720p at 30 fps when supported.';
      });
    } catch (e) {
      await _stopSharing(updateStatus: false);
      if (mounted) setState(() => _status = 'Could not start sharing: $e');
    }
  }

  Future<void> _stopSharing({bool updateStatus = true}) async {
    for (final track in _screen?.getTracks() ?? <MediaStreamTrack>[]) {
      try { track.stop(); } catch (_) {}
    }
    try { await _screen?.dispose(); } catch (_) {}
    _screen = null;
    try { await _socketSub?.cancel(); } catch (_) {}
    _socketSub = null;
    try { await _socket?.close(); } catch (_) {}
    _socket = null;
    try { await _peer?.close(); await _peer?.dispose(); } catch (_) {}
    _peer = null;
    _remoteDescriptionSet = false;
    _pendingIce.clear();
    if (FlutterBackground.isBackgroundExecutionEnabled) {
      try { await FlutterBackground.disableBackgroundExecution(); } catch (_) {}
    }
    if (mounted) setState(() {
      _sharing = false;
      if (updateStatus) _status = 'Sharing stopped.';
    });
  }

  Future<void> _stopReceiver() async {
    try { await _socketSub?.cancel(); } catch (_) {}
    _socketSub = null;
    try { await _socket?.close(); } catch (_) {}
    _socket = null;
    try { await _peer?.close(); await _peer?.dispose(); } catch (_) {}
    _peer = null;
    try { await _httpSub?.cancel(); } catch (_) {}
    _httpSub = null;
    try { await _http?.close(force: true); } catch (_) {}
    _http = null;
    if (_rendererReady) _renderer.srcObject = null;
    if (mounted) setState(() {
      _receiverRunning = false;
      _pin = '';
      _addresses = [];
      _status = 'Receiver stopped.';
    });
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) setState(() => _status = 'Copied to clipboard.');
  }

  @override
  Widget build(BuildContext context) {
    final mode = _effectiveMode(context);
    return Scaffold(
      appBar: AppBar(
        title: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cast, size: 26), SizedBox(width: 10),
          Text('Hyouka Cast', style: TextStyle(fontWeight: FontWeight.w700)),
        ]),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(
              child: Text('LOCAL WI-FI', style: TextStyle(color: _muted, fontSize: 10, letterSpacing: 1.3)),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.all(22),
              children: [
                Row(children: [
                  Expanded(child: _modeButton('PHONE  →  TV', Icons.screen_share, mode == _Mode.phone,
                    () => setState(() => _mode = _Mode.phone))),
                  const SizedBox(width: 10),
                  Expanded(child: _modeButton('TV RECEIVER', Icons.tv, mode == _Mode.tv,
                    () => setState(() => _mode = _Mode.tv))),
                ]),
                const SizedBox(height: 28),
                if (mode == _Mode.phone) _phonePanel(),
                if (mode == _Mode.tv) _tvPanel(),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(border: Border.all(color: _border), borderRadius: BorderRadius.circular(12)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.info_outline, color: _white, size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_status, style: const TextStyle(color: _white, height: 1.4))),
                  ]),
                ),
                const SizedBox(height: 20),
                const Text('Video stays on your local network. No cloud relay or account.',
                  textAlign: TextAlign.center, style: TextStyle(color: _muted, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeButton(String text, IconData icon, bool selected, VoidCallback onPressed) =>
      OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18, color: _white),
        label: Text(text, style: const TextStyle(color: _white, fontSize: 12, letterSpacing: .4)),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: selected ? _white : _border),
          padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );

  Widget _phonePanel() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Icon(Icons.cast_connected, size: 40, color: _white),
    const SizedBox(height: 16),
    const Text('Mirror your phone', style: TextStyle(color: _white, fontSize: 28, fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    const Text('Enter the address and pairing code displayed by Hyouka Cast on your Android TV.',
      style: TextStyle(color: _muted, height: 1.45)),
    const SizedBox(height: 24),
    TextField(controller: _address, keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: const TextStyle(color: _white),
      decoration: const InputDecoration(labelText: 'TV IPv4 address', hintText: '192.168.1.50',
        prefixIcon: Icon(Icons.router, color: _white))),
    const SizedBox(height: 14),
    TextField(controller: _pinInput, keyboardType: TextInputType.number, maxLength: 6,
      style: const TextStyle(color: _white, letterSpacing: 5),
      decoration: const InputDecoration(labelText: 'Six-digit pairing code',
        prefixIcon: Icon(Icons.lock_outline, color: _white), counterText: '')),
    const SizedBox(height: 18),
    _action(_sharing ? 'STOP SHARING' : 'CONNECT & SHARE',
      _sharing ? Icons.stop_circle_outlined : Icons.play_arrow,
      _sharing ? _stopSharing : _startSharing),
    const SizedBox(height: 18),
    _detail(Icons.speed, 'WebRTC stream', 'Direct peer-to-peer video on local Wi-Fi'),
    _detail(Icons.high_quality, 'Capture target', 'Up to 720p / 30 fps, hardware permitting'),
    _detail(Icons.wifi, 'Network', 'Same access point; client isolation must be off'),
  ]);

  Widget _tvPanel() {
    final connected = _rendererReady && _renderer.srcObject != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.connected_tv, size: 42, color: _white),
      const SizedBox(height: 15),
      const Text('TV receiver', style: TextStyle(color: _white, fontSize: 30, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      const Text('Start receiver, then type its local address and code into the phone app.',
        style: TextStyle(color: _muted, height: 1.45)),
      const SizedBox(height: 20),
      Container(
        height: 260, width: double.infinity,
        decoration: BoxDecoration(border: Border.all(color: _border), borderRadius: BorderRadius.circular(16)),
        child: connected
            ? ClipRRect(borderRadius: BorderRadius.circular(16), child: RTCVideoView(
                _renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain))
            : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.tv, size: 54, color: _white), SizedBox(height: 14),
                Text('Waiting for a phone', style: TextStyle(color: _white, fontSize: 18)),
                SizedBox(height: 6), Text('The mirrored screen will appear here.', style: TextStyle(color: _muted)),
              ]),
      ),
      const SizedBox(height: 20),
      if (_receiverRunning) ...[
        const Text('TV ADDRESSES', style: TextStyle(color: _muted, fontSize: 11, letterSpacing: 1.3)),
        const SizedBox(height: 8),
        ..._addresses.map((address) => Row(children: [
          Expanded(child: Text('$address:$_port', style: const TextStyle(color: _white, fontSize: 17))),
          IconButton(tooltip: 'Copy address', onPressed: () => _copy(address),
            icon: const Icon(Icons.copy, color: _white)),
        ])),
        const SizedBox(height: 12),
        const Text('PAIRING CODE', style: TextStyle(color: _muted, fontSize: 11, letterSpacing: 1.3)),
        Row(children: [
          Expanded(child: Text(_pin, style: const TextStyle(color: _white, fontSize: 34, letterSpacing: 7, fontWeight: FontWeight.w700))),
          IconButton(tooltip: 'Copy code', onPressed: () => _copy(_pin),
            icon: const Icon(Icons.copy, color: _white)),
        ]),
      ],
      const SizedBox(height: 14),
      _action(_receiverRunning ? 'STOP RECEIVER' : 'START TV RECEIVER',
        _receiverRunning ? Icons.stop_circle_outlined : Icons.play_arrow,
        _receiverRunning ? _stopReceiver : _startReceiver),
    ]);
  }

  Widget _action(String label, IconData icon, VoidCallback action) => SizedBox(
    width: double.infinity,
    child: OutlinedButton.icon(
      onPressed: action, icon: Icon(icon, color: _white),
      label: Text(label, style: const TextStyle(color: _white, fontWeight: FontWeight.w700, letterSpacing: .6)),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: _white),
        padding: const EdgeInsets.symmetric(vertical: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );

  Widget _detail(IconData icon, String heading, String body) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Row(children: [
      Icon(icon, color: _white, size: 19), const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(heading, style: const TextStyle(color: _white, fontWeight: FontWeight.w600)),
        const SizedBox(height: 3), Text(body, style: const TextStyle(color: _muted, fontSize: 12)),
      ])),
    ]),
  );
}
