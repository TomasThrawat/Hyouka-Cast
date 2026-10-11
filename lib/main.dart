import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

const _castPlatform = MethodChannel('cast_android');

const _port = 38741;
const int _targetFrameRate = 60;
const int _screenShareMaxBitrateBps = 8000000;
const Duration _statsSampleInterval = Duration(seconds: 2);
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
  Timer? _statsTimer;
  bool _statsSampleInFlight = false;
  int _statsGeneration = 0;
  int _sessionGeneration = 0;
  int? _lastVideoFrameCount;
  int? _lastVideoBytes;
  DateTime? _lastVideoStatsAt;
  String _streamStatsText = 'Waiting for stream stats…';
  HttpServer? _http;
  bool _receiverUpgradePending = false;
  StreamSubscription<HttpRequest>? _httpSub;
  StreamSubscription<dynamic>? _socketSub;
  WebSocket? _socket;
  RTCPeerConnection? _peer;
  MediaStream? _screen;
  bool _tvRoleKnown = false;
  bool _isTvDevice = false;
  bool _rendererReady = false;
  bool _receiverRunning = false;
  bool _startingReceiver = false;
  bool _sharing = false;
  bool _startingSharing = false;
  bool _remoteDescriptionSet = false;
  String _pin = '';
  String _status = 'Ready';
  List<String> _addresses = [];

  @override
  void initState() {
    super.initState();
    _detectDeviceRole();
  }

  Future<void> _detectDeviceRole() async {
    try {
      final isTv = await _castPlatform.invokeMethod<bool>('isTvDevice') ?? false;
      if (!mounted) return;
      setState(() {
        _isTvDevice = isTv;
        _tvRoleKnown = true;
      });
    } catch (_) {
      // Keep the UI usable in widget tests or on a platform without the helper.
      if (!mounted) return;
      setState(() {
        _isTvDevice = MediaQuery.sizeOf(context).width >= 800;
        _tvRoleKnown = true;
      });
    }
  }

  _Mode _effectiveMode(BuildContext context) {
    final isTv = _tvRoleKnown
        ? _isTvDevice
        : MediaQuery.sizeOf(context).width >= 800;
    return isTv ? _Mode.tv : _Mode.phone;
  }

  @override
  void dispose() {
    _sessionGeneration++;
    _stopStreamStats();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const []);
    _address.dispose();
    _pinInput.dispose();
    unawaited(_httpSub?.cancel());
    _http?.close(force: true);
    _httpSub = null;
    _http = null;
    unawaited(_socketSub?.cancel());
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(socket.close());
    final peer = _peer;
    _peer = null;
    unawaited(_closePeerConnection(peer));
    unawaited(_stopLocalCaptureAndBackground());
    if (_rendererReady) unawaited(_renderer.dispose());
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
    if (_receiverRunning || _startingReceiver) return;

    setState(() {
      _startingReceiver = true;
      _status = 'Starting local Wi-Fi receiver…';
    });

    try {
      await SystemChrome.setPreferredOrientations(
        const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
      );
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

      final addresses = await _getLanAddresses();
      final pin = (100000 + Random.secure().nextInt(900000)).toString();
      final server = await HttpServer.bind(InternetAddress.anyIPv4, _port, shared: true);
      _http = server;
      _pin = pin;
      _addresses = addresses;
      _httpSub = server.listen(_handleRequest);

      if (!mounted) {
        await _httpSub?.cancel();
        _httpSub = null;
        await server.close(force: true);
        _http = null;
        return;
      }

      setState(() {
        _receiverRunning = true;
        _status = addresses.isEmpty
            ? 'Receiver started, but no private IPv4 address was found.'
            : 'Ready. Connect your phone to this TV over the same Wi-Fi.';
      });
    } catch (e) {
      try {
        await _httpSub?.cancel();
      } catch (_) {}
      _httpSub = null;
      try {
        await _http?.close(force: true);
      } catch (_) {}
      _http = null;
      _pin = '';
      _addresses = [];

      try {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        await SystemChrome.setPreferredOrientations(const []);
      } catch (_) {}

      if (mounted) setState(() => _status = 'Receiver failed: $e');
    } finally {
      if (mounted) {
        setState(() => _startingReceiver = false);
      } else {
        _startingReceiver = false;
      }
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

    if (_receiverUpgradePending) {
      request.response.statusCode = HttpStatus.conflict;
      await request.response.close();
      return;
    }

    _receiverUpgradePending = true;
    final sessionGeneration = ++_sessionGeneration;
    WebSocket? socket;
    try {
      final previousSocket = _socket;
      _socket = null;
      final previousPeer = _peer;
      _peer = null;
      _remoteDescriptionSet = false;
      _pendingIce.clear();
      _stopStreamStats();
      try { await _socketSub?.cancel(); } catch (_) {}
      _socketSub = null;
      if (previousSocket != null && previousSocket.readyState == WebSocket.open) {
        try { await previousSocket.close().timeout(const Duration(seconds: 2)); } catch (_) {}
      }
      await _closePeerConnection(previousPeer);
      if (sessionGeneration != _sessionGeneration || !mounted) return;

      socket = await WebSocketTransformer.upgrade(request);
      if (sessionGeneration != _sessionGeneration || !mounted) {
        try { await socket.close(); } catch (_) {}
        return;
      }
      _socket = socket;
      _listen(socket);
      await _createPeer();
      if (sessionGeneration == _sessionGeneration && identical(_socket, socket) && mounted) {
        setState(() => _status = 'Phone paired. Waiting for the screen…');
      }
    } catch (e) {
      if (sessionGeneration == _sessionGeneration) {
        if (identical(_socket, socket)) _socket = null;
        try { await socket?.close(); } catch (_) {}
        if (mounted) setState(() => _status = 'Connection failed: $e');
      } else {
        try { await socket?.close(); } catch (_) {}
      }
    } finally {
      _receiverUpgradePending = false;
    }
  }

  double? _statNumber(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  void _startStreamStats() {
    _statsGeneration++;
    _statsSampleInFlight = false;
    _statsTimer?.cancel();
    _lastVideoFrameCount = null;
    _lastVideoBytes = null;
    _lastVideoStatsAt = null;
    if (mounted) {
      setState(() => _streamStatsText = 'Measuring video…');
    } else {
      _streamStatsText = 'Measuring video…';
    }
    unawaited(_updateStreamStats());
    _statsTimer = Timer.periodic(_statsSampleInterval, (_) {
      unawaited(_updateStreamStats());
    });
  }

  void _stopStreamStats() {
    _statsGeneration++;
    _statsTimer?.cancel();
    _statsTimer = null;
    _statsSampleInFlight = false;
    _lastVideoFrameCount = null;
    _lastVideoBytes = null;
    _lastVideoStatsAt = null;
    _streamStatsText = 'Waiting for stream stats…';
  }

  Future<void> _updateStreamStats() async {
    if (_statsSampleInFlight) return;
    final peer = _peer;
    if (peer == null) return;
    final generation = _statsGeneration;

    _statsSampleInFlight = true;
    try {
      final reports = await peer.getStats();
      if (generation != _statsGeneration || !identical(peer, _peer)) return;
      final wantedType = _isTvDevice ? 'inbound-rtp' : 'outbound-rtp';
      StatsReport? videoReport;
      for (final report in reports) {
        if (report.type != wantedType) continue;
        final mediaType = report.values['kind'] ?? report.values['mediaType'];
        if (mediaType != null && mediaType.toString().toLowerCase() != 'video') {
          continue;
        }
        videoReport = report;
        break;
      }
      if (videoReport == null) return;

      final values = videoReport.values;
      final isReceiving = wantedType == 'inbound-rtp';
      final framesKey = isReceiving ? 'framesDecoded' : 'framesEncoded';
      final bytesKey = isReceiving ? 'bytesReceived' : 'bytesSent';
      final now = DateTime.now();
      final elapsedMs = _lastVideoStatsAt == null
          ? 0
          : now.difference(_lastVideoStatsAt!).inMilliseconds;
      final frames = _statNumber(values[framesKey])?.round();
      final bytes = _statNumber(values[bytesKey])?.round();
      var fps = _statNumber(values['framesPerSecond']);
      if ((fps == null || fps <= 0) &&
          frames != null &&
          _lastVideoFrameCount != null &&
          elapsedMs > 0 &&
          frames >= _lastVideoFrameCount!) {
        fps = (frames - _lastVideoFrameCount!) * 1000 / elapsedMs;
      }
      double? mbps;
      if (bytes != null &&
          _lastVideoBytes != null &&
          elapsedMs > 0 &&
          bytes >= _lastVideoBytes!) {
        mbps = (bytes - _lastVideoBytes!) * 8 / elapsedMs / 1000;
      }
      if (frames != null) _lastVideoFrameCount = frames;
      if (bytes != null) _lastVideoBytes = bytes;
      _lastVideoStatsAt = now;

      final direction = isReceiving ? 'RX' : 'TX';
      final fpsText = fps == null ? 'FPS measuring' : '${fps.round()} FPS';
      final rateText = mbps == null ? 'bitrate measuring' : '${mbps.toStringAsFixed(1)} Mbps';
      final nextText = '$direction · $fpsText · $rateText';
      if (mounted && nextText != _streamStatsText) {
        setState(() => _streamStatsText = nextText);
      } else {
        _streamStatsText = nextText;
      }
      debugPrint('[HyoukaCast][StreamStats] $nextText');
    } catch (error) {
      debugPrint('[HyoukaCast][StreamStats] Stats unavailable: $error');
    } finally {
      if (generation == _statsGeneration) _statsSampleInFlight = false;
    }
  }

  Future<void> _configureVideoSender(RTCPeerConnection peer) async {
    try {
      final senders = await peer.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind != 'video') continue;
        final parameters = sender.parameters;
        final encodings = parameters.encodings;
        if (encodings == null || encodings.isEmpty) {
          debugPrint('[HyoukaCast][Video] No RTP encoding exposed; keeping WebRTC defaults.');
          continue;
        }
        encodings.first
          ..maxFramerate = _targetFrameRate
          ..maxBitrate = _screenShareMaxBitrateBps;
        // Preserve image detail under load; WebRTC may lower frame rate rather
        // than aggressively reducing resolution. Keep bitrate high enough for
        // readable text and fine details on a local Wi-Fi link.
        parameters.degradationPreference = RTCDegradationPreference.MAINTAIN_RESOLUTION;
        final applied = await sender.setParameters(parameters);
        debugPrint(
          '[HyoukaCast][Video] encoder cap=$_targetFrameRate fps, '
          'bitrate=$_screenShareMaxBitrateBps bps, '
          'maintain-resolution; applied=$applied',
        );
      }
    } catch (error) {
      // Older device codecs may reject optional RTP tuning. Keep mirroring usable.
      debugPrint('[HyoukaCast][Video] RTP tuning unavailable; using WebRTC defaults: $error');
    }
  }

  Future<void> _closePeerConnection(RTCPeerConnection? peer) async {
    if (peer == null) return;
    try { await peer.close(); } catch (_) {}
    try { await peer.dispose(); } catch (_) {}
  }

  Future<void> _createPeer() async {
    final sessionGeneration = _sessionGeneration;
    final previousPeer = _peer;
    _peer = null;
    await _closePeerConnection(previousPeer);
    if (sessionGeneration != _sessionGeneration || !mounted) return;

    final peer = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    if (sessionGeneration != _sessionGeneration || !mounted) {
      await _closePeerConnection(peer);
      return;
    }
    _peer = peer;
    _remoteDescriptionSet = false;
    _pendingIce.clear();
    peer.onIceCandidate = (candidate) {
      if (!identical(_peer, peer)) return;
      if (candidate.candidate != null && candidate.candidate!.isNotEmpty) {
        _send({'type': 'ice', 'candidate': candidate.toMap()});
      }
    };
    peer.onTrack = (event) async {
      if (!identical(_peer, peer) || event.streams.isEmpty) return;
      await _initRenderer();
      if (!identical(_peer, peer)) return;
      _renderer.srcObject = event.streams.first;
      if (mounted) setState(() => _status = 'Live screen received over Wi-Fi.');
      _startStreamStats();
    };
    peer.onConnectionState = (state) {
      if (!identical(_peer, peer) || !mounted) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        setState(() => _status = 'Connected over local Wi-Fi.');
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        final activeSocket = _socket;
        if (activeSocket != null) {
          unawaited(_handleReceiverSocketClosed(
            activeSocket,
            status: _isTvDevice
                ? 'Video connection failed. Receiver is ready; reconnect from the phone.'
                : 'Video connection failed. Screen sharing stopped; reconnect to the TV.',
          ));
        } else {
          setState(() => _status = 'Video connection failed. Check Wi-Fi and reconnect.');
        }
      }
    };
  }

  void _listen(WebSocket socket) {
    _socketSub?.cancel();
    _socketSub = socket.listen(
      (data) => _handleSignal(data, socket),
      onDone: () {
        unawaited(_handleReceiverSocketClosed(socket));
      },
      onError: (Object e) {
        unawaited(_handleReceiverSocketClosed(
          socket,
          status: 'Local socket error: $e',
        ));
      },
    );
  }

  Future<void> _handleReceiverSocketClosed(
    WebSocket socket, {
    String? status,
  }) async {
    if (!identical(_socket, socket)) return;

    final cleanupGeneration = ++_sessionGeneration;
    _socket = null;
    _socketSub = null;
    _stopStreamStats();
    final peer = _peer;
    _peer = null;
    _remoteDescriptionSet = false;
    _pendingIce.clear();

    if (socket.readyState == WebSocket.open) {
      try { await socket.close().timeout(const Duration(seconds: 1)); } catch (_) {}
    }
    if (!_isTvDevice) await _stopLocalCaptureAndBackground();
    await _closePeerConnection(peer);
    // A reconnect may complete while native teardown is awaited. Never clear its
    // renderer or overwrite the state of the newer session.
    if (cleanupGeneration != _sessionGeneration) return;

    if (_rendererReady) _renderer.srcObject = null;
    final nextStatus = status ?? (_isTvDevice
        ? 'Phone stopped casting. Receiver is ready.'
        : 'TV disconnected. Screen sharing stopped; reconnect when the TV is ready.');
    if (mounted) {
      setState(() {
        _sharing = false;
        _status = nextStatus;
      });
    } else {
      _sharing = false;
      _status = nextStatus;
    }
  }

  Future<void> _handleSignal(dynamic data, WebSocket socket) async {
    final sessionGeneration = _sessionGeneration;
    bool isCurrentSession() =>
        sessionGeneration == _sessionGeneration && identical(_socket, socket);
    if (!isCurrentSession()) return;

    try {
      final text = data is String ? data : utf8.decode(data as List<int>);
      final msg = jsonDecode(text) as Map<String, dynamic>;
      switch (msg['type']) {
        case 'offer':
          if (_peer == null) await _createPeer();
          if (!isCurrentSession() || _peer == null) return;
          final peer = _peer!;
          final sdp = msg['sdp'] as String?;
          if (sdp == null) throw const FormatException('Missing offer SDP.');
          await peer.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
          if (!isCurrentSession() || !identical(_peer, peer)) return;
          _remoteDescriptionSet = true;
          await _flushIce(peer);
          if (!isCurrentSession() || !identical(_peer, peer)) return;
          final answer = await peer.createAnswer();
          if (!isCurrentSession() || !identical(_peer, peer)) return;
          await peer.setLocalDescription(answer);
          if (!isCurrentSession() || !identical(_peer, peer)) return;
          _send({'type': 'answer', 'sdp': answer.sdp});
          break;
        case 'answer':
          if (_peer == null) throw StateError('Received an answer before peer setup.');
          final peer = _peer!;
          final sdp = msg['sdp'] as String?;
          if (sdp == null) throw const FormatException('Missing answer SDP.');
          await peer.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
          if (!isCurrentSession() || !identical(_peer, peer)) return;
          _remoteDescriptionSet = true;
          await _flushIce(peer);
          break;
        case 'ice':
          final raw = msg['candidate'];
          if (raw is Map) {
            final m = Map<String, dynamic>.from(raw);
            final candidate = RTCIceCandidate(
              m['candidate'] as String?,
              m['sdpMid'] as String?,
              (m['sdpMLineIndex'] as num?)?.toInt(),
            );
            if (_remoteDescriptionSet) {
              final peer = _peer;
              if (peer != null && isCurrentSession()) await peer.addCandidate(candidate);
            } else {
              _pendingIce.add(candidate);
            }
          }
          break;
        case 'error':
          if (mounted && isCurrentSession()) {
            setState(() => _status = (msg['message'] as String?) ?? 'Remote error.');
          }
          break;
      }
    } catch (e) {
      if (mounted && isCurrentSession()) setState(() => _status = 'Signaling error: $e');
    }
  }

  Future<void> _flushIce(RTCPeerConnection peer) async {
    final queued = List<RTCIceCandidate>.from(_pendingIce);
    _pendingIce.clear();
    for (final candidate in queued) {
      if (!identical(_peer, peer)) return;
      await peer.addCandidate(candidate);
    }
  }

  void _send(Map<String, dynamic> msg) {
    final ws = _socket;
    if (ws != null && ws.readyState == WebSocket.open) ws.add(jsonEncode(msg));
  }

  Future<void> _startSharing() async {
    if (_sharing || _startingSharing) return;

    final host = _address.text.trim();
    final pin = _pinInput.text.trim();
    final ip = InternetAddress.tryParse(host);
    final isPrivateIpv4 = ip != null &&
        ip.type == InternetAddressType.IPv4 &&
        (ip.address.startsWith('192.168.') ||
            ip.address.startsWith('10.') ||
            _private172(ip.address));
    if (!isPrivateIpv4) {
      setState(() => _status =
          'Enter the TV private Wi-Fi IPv4 address, for example 192.168.1.50.');
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      setState(() => _status = 'Enter the six-digit code shown on the TV.');
      return;
    }

    setState(() {
      _startingSharing = true;
      _status = 'Connecting to TV over Wi-Fi…';
    });

    final sessionGeneration = ++_sessionGeneration;
    WebSocket? sessionSocket;
    RTCPeerConnection? sessionPeer;
    void ensureActiveSession() {
      if (sessionGeneration != _sessionGeneration ||
          sessionSocket == null ||
          !identical(_socket, sessionSocket) ||
          sessionPeer == null ||
          !identical(_peer, sessionPeer)) {
        throw StateError('The TV connection was interrupted. Connect again.');
      }
    }

    try {
      final uri = Uri(
        scheme: 'ws', host: host, port: _port, path: '/signal',
        queryParameters: {'pin': pin},
      );
      final ws = await WebSocket.connect(uri.toString()).timeout(const Duration(seconds: 10));
      if (!mounted || sessionGeneration != _sessionGeneration) {
        try { await ws.close(); } catch (_) {}
        return;
      }
      sessionSocket = ws;
      _socket = ws;
      _listen(ws);
      await _createPeer();
      sessionPeer = _peer;
      ensureActiveSession();

      final consent = await Helper.requestCapturePermission(fullScreenOnly: true);
      ensureActiveSession();
      if (!consent) throw StateError('Screen-capture permission was not granted.');

      final initialized = await FlutterBackground.initialize(
        androidConfig: const FlutterBackgroundAndroidConfig(
          notificationTitle: 'Hyouka Cast',
          notificationText: 'Sharing your screen on local Wi-Fi.',
          notificationImportance: AndroidNotificationImportance.normal,
          notificationIcon: AndroidResource(name: 'ic_stat_cast', defType: 'drawable'),
          enableWifiLock: true,
          // The foreground service is allowed without excluding this app from
          // battery optimization. Requiring that exemption made initialize()
          // return false on devices where the user had not granted it.
          shouldRequestBatteryOptimizationsOff: false,
        ),
      );
      ensureActiveSession();
      if (!initialized) throw StateError('Could not initialize the screen-sharing service.');
      final backgroundStarted = await FlutterBackground.enableBackgroundExecution();
      ensureActiveSession();
      if (!backgroundStarted) throw StateError('Android did not start the foreground service.');

      _screen = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
      ensureActiveSession();
      for (final track in _screen!.getVideoTracks()) {
        await sessionPeer!.addTrack(track, _screen!);
        ensureActiveSession();
      }
      await _configureVideoSender(sessionPeer!);
      ensureActiveSession();
      final offer = await sessionPeer!.createOffer();
      ensureActiveSession();
      await sessionPeer!.setLocalDescription(offer);
      ensureActiveSession();
      _send({'type': 'offer', 'sdp': offer.sdp});
      if (mounted) {
        setState(() {
          _sharing = true;
          _status = 'Sharing screen. Target is up to 60 fps at up to 1920 × 1080, depending on hardware.';
        });
      }
      _startStreamStats();
    } catch (e) {
      await _stopSharing(updateStatus: false);
      if (mounted) setState(() => _status = 'Could not start sharing: $e');
    } finally {
      if (mounted) {
        setState(() => _startingSharing = false);
      } else {
        _startingSharing = false;
      }
    }
  }

  Future<void> _stopLocalCaptureAndBackground() async {
    final screen = _screen;
    _screen = null;
    for (final track in screen?.getTracks() ?? <MediaStreamTrack>[]) {
      try { track.stop(); } catch (_) {}
    }
    try { await screen?.dispose(); } catch (_) {}
    if (FlutterBackground.isBackgroundExecutionEnabled) {
      try { await FlutterBackground.disableBackgroundExecution(); } catch (_) {}
    }
  }

  Future<void> _stopSharing({bool updateStatus = true}) async {
    _sessionGeneration++;
    _stopStreamStats();
    final socketSub = _socketSub;
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    final peer = _peer;
    _peer = null;
    _remoteDescriptionSet = false;
    _pendingIce.clear();

    await _stopLocalCaptureAndBackground();
    try { await socketSub?.cancel(); } catch (_) {}
    try { await socket?.close(); } catch (_) {}
    await _closePeerConnection(peer);
    if (mounted) {
      setState(() {
        _sharing = false;
        if (updateStatus) _status = 'Sharing stopped.';
      });
    }
  }

  Future<void> _stopReceiver() async {
    _sessionGeneration++;
    _stopStreamStats();
    final socketSub = _socketSub;
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    final peer = _peer;
    _peer = null;
    _remoteDescriptionSet = false;
    _pendingIce.clear();
    final httpSub = _httpSub;
    _httpSub = null;
    final http = _http;
    _http = null;

    try { await socketSub?.cancel(); } catch (_) {}
    try { await socket?.close(); } catch (_) {}
    await _closePeerConnection(peer);
    try { await httpSub?.cancel(); } catch (_) {}
    try { await http?.close(force: true); } catch (_) {}
    if (_rendererReady) _renderer.srcObject = null;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const []);
    if (mounted) {
      setState(() {
        _receiverRunning = false;
        _pin = '';
        _addresses = [];
        _status = 'Receiver stopped.';
      });
    }
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) setState(() => _status = 'Copied to clipboard.');
  }

  @override
  Widget build(BuildContext context) {
    final mode = _effectiveMode(context);
    final showFullscreenReceiver = mode == _Mode.tv &&
        _receiverRunning && _rendererReady && _renderer.srcObject != null;
    return PopScope<Object?>(
      canPop: !_receiverRunning,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _receiverRunning && mounted) {
          setState(() => _status = 'Casting stays active. Stop casting from your phone to end the session.');
        }
      },
      child: Scaffold(
      appBar: showFullscreenReceiver ? null : AppBar(
        leading: const Icon(Icons.cast, size: 24),
        title: const Text(
          'Hyouka Cast',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: showFullscreenReceiver
          ? Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: _black),
                RTCVideoView(
                  _renderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: SafeArea(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0x99000000),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: _border),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                        child: Text(
                          'HYOUKA CAST  •  LIVE\n$_streamStatsText',
                          textAlign: TextAlign.right,
                          style: const TextStyle(color: _white, fontSize: 12, height: 1.5, letterSpacing: .3),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.all(22),
              children: [
                const SizedBox(height: 8),
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
      ),
    );
  }

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
    _action(
      _sharing ? 'STOP SHARING' : _startingSharing ? 'CONNECTING…' : 'CONNECT & SHARE',
      _sharing
          ? Icons.stop_circle_outlined
          : _startingSharing
              ? Icons.hourglass_empty
              : Icons.play_arrow,
      _sharing ? _stopSharing : _startingSharing ? null : _startSharing,
    ),
    const SizedBox(height: 18),
    _detail(Icons.speed, 'WebRTC stream', 'Direct peer-to-peer video on local Wi-Fi'),
    _detail(Icons.high_quality, 'Capture target', 'Up to 1920 × 1080 / 60 fps, hardware permitting'),
    _detail(Icons.monitor_heart_outlined, 'Live video stats', _streamStatsText),
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
        height: 180, width: double.infinity,
        decoration: BoxDecoration(border: Border.all(color: _border), borderRadius: BorderRadius.circular(16)),
        child: connected
            ? const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.fullscreen, size: 48, color: _white),
                SizedBox(height: 12),
                Text('Phone screen is now full-screen.', style: TextStyle(color: _white, fontSize: 18)),
                SizedBox(height: 6),
                Text('Receiver stays open until casting is stopped from the phone.', style: TextStyle(color: _muted)),
              ])
            : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.tv, size: 54, color: _white), SizedBox(height: 14),
                Text('Waiting for a phone', style: TextStyle(color: _white, fontSize: 18)),
                SizedBox(height: 6), Text('The mirrored screen will appear here.', style: TextStyle(color: _muted)),
              ]),
      ),
      _detail(Icons.monitor_heart_outlined, 'Live video stats', _streamStatsText),
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
      _action(
        _receiverRunning
            ? 'STOP RECEIVER'
            : _startingReceiver
                ? 'STARTING RECEIVER…'
                : 'START TV RECEIVER',
        _receiverRunning
            ? Icons.stop_circle_outlined
            : _startingReceiver
                ? Icons.hourglass_empty
                : Icons.play_arrow,
        _receiverRunning ? _stopReceiver : _startingReceiver ? null : _startReceiver,
      ),
    ]);
  }

  Widget _action(String label, IconData icon, VoidCallback? action) => SizedBox(
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
