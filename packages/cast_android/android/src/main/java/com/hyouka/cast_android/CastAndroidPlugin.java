package com.hyouka.cast_android;

import android.content.res.Configuration;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodChannel;

/** Registers Android TV detection for the one-way phone-to-TV cast app. */
public final class CastAndroidPlugin implements FlutterPlugin {
    private MethodChannel channel;

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        channel = new MethodChannel(binding.getBinaryMessenger(), "cast_android");
        channel.setMethodCallHandler((call, result) -> {
            if ("isTvDevice".equals(call.method)) {
                int deviceType = binding.getApplicationContext()
                        .getResources()
                        .getConfiguration()
                        .uiMode & Configuration.UI_MODE_TYPE_MASK;
                result.success(deviceType == Configuration.UI_MODE_TYPE_TELEVISION);
            } else {
                result.notImplemented();
            }
        });
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        if (channel != null) {
            channel.setMethodCallHandler(null);
            channel = null;
        }
    }
}
