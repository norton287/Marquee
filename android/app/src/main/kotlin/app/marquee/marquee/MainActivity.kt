package app.marquee.marquee

import com.ryanheise.audioservice.AudioServiceActivity
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
    override fun onDestroy() {
        val finishing = isFinishing
        super.onDestroy()
        if (finishing && MarqueeApplication.isTv(this)) {
            AudioServicePlugin.disposeFlutterEngine()
        }
    }
}
