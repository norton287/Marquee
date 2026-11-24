package app.marquee.marquee

import android.app.Application
import android.content.Context
import app.marquee.engine_hook.EngineHookPlugin
import com.ryanheise.audioservice.AudioServicePlugin

/**
 * When Android Auto connects while Marquee isn't running, Android starts this
 * process for the media service only. audio_service answers the car with an
 * empty menu until Dart is running, and nothing else would start it, so the
 * engine (and main()) is started here. Phones and tablets only: a TV has no
 * background music.
 *
 * Every Flutter engine (this first one, audio_service's later ones started by
 * the service with no window, the activity's) gets the car-log watch and the
 * voice channel through engine_hook's plugin, which Flutter registers on each.
 */
class MarqueeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (isTv(this)) return
        EngineHookPlugin.onEngine = { context, messenger ->
            CarWatch.attach(context, messenger)
            VoiceSearch.attach(messenger)
        }
        AudioServicePlugin.getFlutterEngine(this)
    }

    companion object {
        fun isTv(context: Context): Boolean {
            val pm = context.packageManager
            return pm.hasSystemFeature("android.software.leanback") ||
                pm.hasSystemFeature("amazon.hardware.fire_tv")
        }
    }
}
