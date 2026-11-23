package app.marquee.marquee

import android.content.Intent
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import com.ryanheise.audioservice.AudioServicePlugin

/**
 * Shares audio_service's Flutter engine, so music, the lock screen and
 * Android Auto run in the same Dart as the app.
 *
 * On a TV nothing plays in the background, and leaving the app must start it
 * fresh next time (as before audio_service): once the activity is finishing
 * (and its plugins have detached) the shared engine is destroyed.
 */
class MainActivity : AudioServiceActivity() {
    // A new engine after the old one was thrown away: the car log's session
    // watch must talk to it (MarqueeApplication attaches only the first).
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!MarqueeApplication.isTv(this)) {
            CarWatch.attach(this, flutterEngine)
            VoiceSearch.attach(flutterEngine)
        }
    }

    // "Hey Google, play … on Marquee": opened (or brought back) with a
    // MEDIA_PLAY_FROM_SEARCH intent. Not again when Android recreates the
    // activity from saved state.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null && !MarqueeApplication.isTv(this)) VoiceSearch.handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (!MarqueeApplication.isTv(this)) VoiceSearch.handle(intent)
    }

    override fun onDestroy() {
        val finishing = isFinishing
        super.onDestroy()
        if (finishing && MarqueeApplication.isTv(this)) {
            AudioServicePlugin.disposeFlutterEngine()
        }
    }
}
