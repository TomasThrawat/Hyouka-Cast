# Hyouka Cast

Pure-black Flutter screen mirroring from an Android phone (Android 12) to an Android TV (Android 14) over the same local Wi-Fi network.

## Device roles

- Install Hyouka Cast on both devices. Choose Phone → TV on the phone and TV Receiver on the television.
- Start the receiver on the TV, then note its local IPv4 address and six-digit pairing code.
- Enter both values on the phone, tap Connect & Share, and approve Android's system screen-capture prompt.
- This app is not a generic Chromecast client: a stock TV without Hyouka Cast installed will not receive the stream.

## Transport and performance

WebRTC carries video peer-to-peer over the local network. A WebSocket on the TV exchanges SDP and ICE signaling; a pairing code gates the signaling connection. The initial capture target is 720p at 30 fps. Actual latency and frame rate depend on Wi-Fi congestion, display/encoding load and the TV decoder. For best performance, use a strong 5 GHz Wi-Fi connection, keep both devices on one access point, and disable client isolation if enabled. No cloud relay or account is required.

Android 14+ requires fresh consent for each MediaProjection capture session. See https://developer.android.com/about/versions/14/behavior-changes-14.

## CI

The app calls TomasThrawat/hyouka-flutter-workflows/.github/workflows/flutter-ci.yml pinned to commit 4c901733066d54e9628b21973dc0badd8f2bd36d. CI builds only two APK artifacts: arm64-v8a for the phone and armeabi-v7a (ARM 32-bit) for the TV. x86_64 is intentionally not built. Dependency upgrades are not automatic.

Local signaling uses TCP port 38741 on the TV. Router/client isolation must permit traffic between devices.