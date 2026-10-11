import 'dart:math' as math;

/// A conservative bitrate-cap controller for a single outgoing screen-share.
///
/// WebRTC's native congestion control remains enabled. This only adjusts the
/// sender's maximum bitrate when network measurements show sustained trouble.
class AdaptiveBitrateController {
  static const int defaultMinimumBitrateBps = 1000000;
  static const int defaultMaximumBitrateBps = 8000000;
  static const int _recoverySamples = 6;
  static const int _minimumMeaningfulChangeBps = 200000;

  AdaptiveBitrateController({
    this.minimumBitrateBps = defaultMinimumBitrateBps,
    this.maximumBitrateBps = defaultMaximumBitrateBps,
  }) : _currentBitrateBps = maximumBitrateBps {
    if (minimumBitrateBps <= 0 || maximumBitrateBps < minimumBitrateBps) {
      throw ArgumentError('Invalid adaptive bitrate bounds.');
    }
  }

  final int minimumBitrateBps;
  final int maximumBitrateBps;

  int _currentBitrateBps;
  int _goodSamples = 0;
  int _badSamples = 0;
  double? _bestRoundTripTimeSeconds;

  int get currentBitrateBps => _currentBitrateBps;

  int reset() {
    _currentBitrateBps = maximumBitrateBps;
    _goodSamples = 0;
    _badSamples = 0;
    _bestRoundTripTimeSeconds = null;
    return _currentBitrateBps;
  }

  /// Returns a proposed cap; call [confirmApplied] only after native WebRTC
  /// confirms that sender.setParameters accepted it.
  ///
  /// Loss is a 0..1 fraction, RTT is in seconds, and bitrate is in bits/sec.
  int? sample({
    double? packetLossFraction,
    double? roundTripTimeSeconds,
    double? availableOutgoingBitrateBps,
    String? qualityLimitationReason,
  }) {
    var loss = packetLossFraction;
    if (loss != null && (!loss.isFinite || loss < 0 || loss > 1)) {
      loss = null;
    }

    var rtt = roundTripTimeSeconds;
    if (rtt != null && (!rtt.isFinite || rtt <= 0 || rtt > 10)) {
      rtt = null;
    }
    if (rtt != null &&
        (_bestRoundTripTimeSeconds == null ||
            rtt < _bestRoundTripTimeSeconds!)) {
      _bestRoundTripTimeSeconds = rtt;
    }

    var available = availableOutgoingBitrateBps;
    if (available != null && (!available.isFinite || available <= 0)) {
      available = null;
    }

    final reason = qualityLimitationReason?.toLowerCase().trim();
    final estimatedCap =
        available == null ? null : _clampBps((available * 0.85).round());
    final elevatedRtt = rtt != null &&
        (rtt >= 0.300 ||
            (_bestRoundTripTimeSeconds != null &&
                rtt - _bestRoundTripTimeSeconds! >= 0.150));
    final severeLoss = loss != null && loss >= 0.10;
    final moderateLoss = loss != null && loss >= 0.04;
    final bandwidthLimited = reason == 'bandwidth';
    final estimateLimited = estimatedCap != null &&
        estimatedCap < _currentBitrateBps * 0.88;

    // A clearly lower native bandwidth estimate is already smoothed by WebRTC.
    if (estimateLimited) {
      _goodSamples = 0;
      _badSamples = 0;
      return _meaningfulTarget(estimatedCap);
    }

    if (severeLoss || moderateLoss || elevatedRtt || bandwidthLimited) {
      _goodSamples = 0;
      _badSamples++;
      // Severe loss warrants immediate reaction. Other signals need two
      // consecutive samples to avoid reacting to a single transient spike.
      if (!severeLoss && _badSamples < 2) return null;

      final factor =
          severeLoss || elevatedRtt || bandwidthLimited ? 0.75 : 0.85;
      return _meaningfulTarget(
        _clampBps((_currentBitrateBps * factor).round()),
      );
    }

    // CPU or other limits are not network evidence; do not ramp up in that case.
    if (reason == 'cpu' || reason == 'other') {
      _goodSamples = 0;
      _badSamples = 0;
      return null;
    }

    final hasNetworkMeasurement =
        loss != null || rtt != null || available != null;
    final cleanLoss = loss == null || loss <= 0.02;
    final enoughBandwidth =
        estimatedCap == null || estimatedCap >= _currentBitrateBps * 1.15;
    if (hasNetworkMeasurement &&
        cleanLoss &&
        !elevatedRtt &&
        enoughBandwidth) {
      _badSamples = 0;
      _goodSamples++;
      if (_goodSamples < _recoverySamples ||
          _currentBitrateBps >= maximumBitrateBps) {
        return null;
      }

      _goodSamples = 0;
      final step = math.max(250000, (_currentBitrateBps * 0.12).round()).toInt();
      final unboundedTarget =
          math.min(maximumBitrateBps, _currentBitrateBps + step).toInt();
      final target = estimatedCap == null
          ? unboundedTarget
          : math.min(unboundedTarget, estimatedCap).toInt();
      return _meaningfulTarget(target);
    }

    _goodSamples = 0;
    _badSamples = 0;
    return null;
  }

  /// Synchronizes controller state with the cap accepted by native WebRTC.
  void confirmApplied(int bitrateBps) {
    _currentBitrateBps = _clampBps(bitrateBps);
    _goodSamples = 0;
    _badSamples = 0;
  }

  int _clampBps(int value) =>
      value.clamp(minimumBitrateBps, maximumBitrateBps).toInt();

  int? _meaningfulTarget(int targetBps) {
    final target = _clampBps(targetBps);
    final minimumChange = math.max(
      _minimumMeaningfulChangeBps,
      (_currentBitrateBps * 0.08).round(),
    );
    if ((target - _currentBitrateBps).abs() < minimumChange) return null;
    return target;
  }
}
