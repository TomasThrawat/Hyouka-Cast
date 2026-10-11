# Hyouka Cast

Pure-black Flutter screen mirroring from an Android phone (Android 12) to an Android TV (Android 14) over the same local Wi-Fi network.

## Device roles

- Install Hyouka Cast on both devices. The app automatically identifies the device: the phone shows only the sender controls, while the Android TV shows only the receiver. There is no TV-to-phone casting mode.
- Start the receiver on the TV, then note its local IPv4 address and six-digit pairing code.
- Enter both values on the phone, tap Connect & Share, and approve Android's system screen-capture prompt. The TV switches to an immersive full-screen view after the video arrives; the app blocks Back navigation while the receiver is active, and the phone's Stop Sharing control ends the session.
- This app is not a generic Chromecast client: a stock TV without Hyouka Cast installed will not receive the stream.

## Transport and performance

WebRTC carries video peer-to-peer over the local network. A WebSocket on the TV exchanges SDP and ICE signaling; a pairing code gates the signaling connection. The Android screen capturer preserves aspect ratio and allows up to 1920 px on the longer display edge and 1080 px on the shorter edge. The sender configures video RTP encoding for up to 60 fps and an initial 12 Mbps bitrate ceiling. A conservative sender-side controller samples WebRTC stats every two seconds and uses the selected ICE candidate-pair bandwidth estimate, remote-reported packet loss/RTT, and encoder quality-limitation reason when those stats are available. It ignores one isolated low bandwidth estimate, reacts immediately to severe packet loss, and requires sustained pressure before lowering its cap. After three clean samples it raises a reduced cap more quickly in controlled steps. The app bounds this extra cap between 1 and 12 Mbps and changes it only when native sender.setParameters succeeds; WebRTC’s own congestion controller remains active. The live sender/receiver stats display the actual RTP frame size when the codec exposes it. This is a guarded ceiling adjustment, not a promise that every Android codec exposes every metric or that it will eliminate all stutter. Actual output remains dependent on the device encoder, Wi-Fi conditions, thermals, display refresh rate, and TV decoder. The app displays actual sender/receiver FPS and measured bitrate when the device exposes those WebRTC statistics. If signaling or the WebRTC peer fails, the app tears down the old session, stops screen capture and its foreground service on the phone, ignores stale messages, and keeps the TV receiver available for a fresh pairing. This is a target, not a guarantee: real performance still depends on display refresh, hardware codec support, thermals, Wi-Fi and the TV decoder. For best performance, use a strong 5 GHz Wi-Fi connection, keep both devices on one access point, and disable client isolation if enabled. No cloud relay or account is required.

**Audio limitation:** this build still mirrors video only. System playback audio is not captured or sent to the TV, and Hyouka Cast does not mute the phone's media output. Android playback-audio capture must be connected to the native WebRTC audio module before those behaviors can be implemented reliably.

Android 14+ requires fresh consent for each MediaProjection capture session. The background service does not require the app to be exempted from battery optimization. See https://developer.android.com/about/versions/14/behavior-changes-14.

## CI

The app calls TomasThrawat/hyouka-flutter-workflows/.github/workflows/flutter-ci.yml pinned to commit 4c901733066d54e9628b21973dc0badd8f2bd36d. CI builds only two APK artifacts: arm64-v8a for the phone and armeabi-v7a (ARM 32-bit) for the TV. x86_64 is intentionally not built. Dependency upgrades are not automatic.

Local signaling uses TCP port 38741 on the TV. Router/client isolation must permit traffic between devices.