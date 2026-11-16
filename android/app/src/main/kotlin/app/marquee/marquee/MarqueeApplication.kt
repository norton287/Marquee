package app.marquee.marquee

import android.app.Application
import android.content.Context
import com.ryanheise.audioservice.AudioServicePlugin

/**
 * When Android Auto connects while Marquee isn't running, Android starts this
 * process for the media service only. audio_service answers the car with an
 * empty menu until Dart is running, and nothing else would start it, so the
 * engine (and main()) is started here. Phones and tablets only: a TV has no
 * background music.
 */
class MarqueeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (!isTv(this)) AudioServicePlugin.getFlutterEngine(this)
    }

    companion object {
        fun isTv(context: Context): Boolean {
            val pm = context.packageManager
            return pm.hasSystemFeature("android.software.leanback") ||
                pm.hasSystemFeature("amazon.hardware.fire_tv")
        }
    }
}
