package app.marquee.engine_hook

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger

/**
 * Flutter registers every plugin on every new engine, including the one
 * audio_service starts for the music service when the car connects with no
 * app window (after Android ended an earlier service, so MarqueeApplication
 * has already run and no activity is there to attach it). That engine's Dart
 * then had no car-log watch and no voice channel ("session watch
 * unavailable: no native side"). This plugin only hands each engine to the
 * app, which sets [onEngine] in MarqueeApplication.onCreate, before any
 * engine exists (a plugin can't depend on the app's own code).
 */
class EngineHookPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onEngine?.invoke(binding.applicationContext, binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    companion object {
        /** Called with each new engine's messenger (newest wins downstream). */
        @JvmStatic
        var onEngine: ((Context, BinaryMessenger) -> Unit)? = null
    }
}
