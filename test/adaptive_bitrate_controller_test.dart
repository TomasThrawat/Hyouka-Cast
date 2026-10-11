import 'package:flutter_test/flutter_test.dart';
import 'package:hyouka_cast/src/adaptive_bitrate_controller.dart';

void main() {
  group('AdaptiveBitrateController', () {
    test('keeps the initial ceiling when no measurements are available', () {
      final controller = AdaptiveBitrateController();

      expect(controller.currentBitrateBps, 8000000);
      expect(controller.sample(), isNull);
      expect(controller.currentBitrateBps, 8000000);
    });

    test('uses a lower bandwidth estimate with a 15 percent safety margin', () {
      final controller = AdaptiveBitrateController();

      final proposed = controller.sample(
        packetLossFraction: 0,
        roundTripTimeSeconds: 0.035,
        availableOutgoingBitrateBps: 2000000,
      );

      expect(proposed, 1700000);
      expect(controller.currentBitrateBps, 8000000);
      controller.confirmApplied(proposed!);
      expect(controller.currentBitrateBps, 1700000);
    });

    test('reacts immediately to severe packet loss', () {
      final controller = AdaptiveBitrateController();

      expect(
        controller.sample(
          packetLossFraction: 0.12,
          roundTripTimeSeconds: 0.04,
        ),
        6000000,
      );
    });

    test('requires two samples for moderate packet loss', () {
      final controller = AdaptiveBitrateController();

      expect(
        controller.sample(packetLossFraction: 0.05, roundTripTimeSeconds: 0.04),
        isNull,
      );
      expect(
        controller.sample(packetLossFraction: 0.05, roundTripTimeSeconds: 0.04),
        6800000,
      );
    });

    test('raises the cap gradually only after stable recovery', () {
      final controller = AdaptiveBitrateController();
      controller.confirmApplied(4000000);

      for (var i = 0; i < 5; i++) {
        expect(
          controller.sample(
            packetLossFraction: 0,
            roundTripTimeSeconds: 0.04,
            availableOutgoingBitrateBps: 12000000,
            qualityLimitationReason: 'none',
          ),
          isNull,
        );
      }
      expect(
        controller.sample(
          packetLossFraction: 0,
          roundTripTimeSeconds: 0.04,
          availableOutgoingBitrateBps: 12000000,
          qualityLimitationReason: 'none',
        ),
        4480000,
      );
    });

    test('does not raise bitrate while limited by CPU', () {
      final controller = AdaptiveBitrateController();
      controller.confirmApplied(4000000);

      for (var i = 0; i < 8; i++) {
        expect(
          controller.sample(
            packetLossFraction: 0,
            roundTripTimeSeconds: 0.04,
            availableOutgoingBitrateBps: 12000000,
            qualityLimitationReason: 'cpu',
          ),
          isNull,
        );
      }
      expect(controller.currentBitrateBps, 4000000);
    });

    test('clamps the estimate to the configured floor', () {
      final controller = AdaptiveBitrateController();

      expect(
        controller.sample(
          packetLossFraction: 0,
          availableOutgoingBitrateBps: 100000,
        ),
        AdaptiveBitrateController.defaultMinimumBitrateBps,
      );
    });
  });
}
