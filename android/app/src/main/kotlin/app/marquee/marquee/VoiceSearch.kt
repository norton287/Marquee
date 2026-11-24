package app.marquee.marquee

import android.app.SearchManager
import android.content.Intent
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * "Hey Google, play … on Marquee" on the phone: the Assistant opens
 * MainActivity with a MEDIA_PLAY_FROM_SEARCH intent (the manifest's intent
 * filter is also what makes the Assistant pick Marquee at all). The words go
 * to Dart (lib/core/voice_search.dart), which plays them like a car's voice
 * request.
 *
 * Dart may not be listening yet (cold start). So the newest request waits: Dart
 * asks for it ('take'), and until Dart has answered once, each request is
 * also pushed ('play'); an answered push means Dart is listening.
 */
object VoiceSearch {
    private const val CHANNEL = "app.marquee.marquee/voice"

    private var messenger: BinaryMessenger? = null
    private var channel: MethodChannel? = null
    private var listening = false
    private var waiting: String? = null

    /** Talks to that engine's Dart from now on (newest engine wins). */
    fun attach(messenger: BinaryMessenger) {
        if (this.messenger === messenger) return
        this.messenger = messenger
        listening = false
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "take") {
                    listening = true
                    result.success(waiting)
                    waiting = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    /** Plays [intent]'s search if it is one; true when it was. */
    fun handle(intent: Intent?): Boolean {
        if (intent?.action != MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH) return false
        // Reopened from Recents: Android hands back the old intent.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return false
        val query = intent.getStringExtra(SearchManager.QUERY) ?: ""
        val c = channel ?: run { waiting = query; return true }
        if (listening) {
            c.invokeMethod("play", query)
            return true
        }
        // Not known to be listening: keep it for 'take', and try a push too.
        // Taken out while the push is in flight so it can't play twice.
        waiting = null
        val sentTo = c
        c.invokeMethod("play", query, object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (channel === sentTo) listening = true
            }
            override fun error(code: String, message: String?, details: Any?) = keep()
            override fun notImplemented() = keep()
            private fun keep() {
                if (waiting == null) waiting = query
            }
        })
        return true
    }
}
