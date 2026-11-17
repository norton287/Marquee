package app.marquee.marquee

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
        if (!MarqueeApplication.isTv(this)) CarWatch.attach(this, flutterEngine)
    }

    override fun onDestroy() {
        val finishing = isFinishing
        super.onDestroy()
        if (finishing && MarqueeApplication.isTv(this)) {
            AudioServicePlugin.disposeFlutterEngine()
        }
    }
}
