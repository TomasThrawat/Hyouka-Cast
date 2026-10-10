package com.hyouka.cast_android;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

/** Registers the TV receiver's Android manifest and launcher metadata. */
public final class CastAndroidPlugin implements FlutterPlugin {
    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        // Manifest metadata is merged by Android; no runtime channel is required.
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        // Nothing to release.
    }
}
