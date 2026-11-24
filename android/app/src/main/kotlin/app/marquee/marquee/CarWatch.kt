package app.marquee.marquee

import android.content.ComponentName
import android.content.Context
import android.media.MediaMetadata
import android.media.browse.MediaBrowser
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Watches Marquee's own media session from the outside, the way Android Auto
 * does, and sends what it sees to the car log ("car sees …"). The Dart side
 * logs what it sends; audio_service hands the song info to Android on a
 * background thread per update, so what arrives (and in which order) can
 * differ. Diagnostics only: it never controls anything.
 */
object CarWatch {
    private const val CHANNEL = "app.marquee.marquee/car_watch"

    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var messenger: BinaryMessenger? = null
    private var controller: MediaController? = null
    private var browser: MediaBrowser? = null
    private var lastItem: String? = null
    private var lastState: String? = null
    private var lastQueue: String? = null

    /**
     * Talks to that engine's Dart from now on. audio_service throws its engine
     * away when the service ends and makes a new one on the next start (the
     * process may live on), so every engine is attached (engine_hook's plugin,
     * from MarqueeApplication), newest wins.
     */
    fun attach(context: Context, messenger: BinaryMessenger) {
        if (this.messenger === messenger) return
        this.messenger = messenger
        val app = context.applicationContext
        channel = MethodChannel(messenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "start") {
                    try {
                        start(app)
                    } catch (e: Exception) {
                        log("watch: couldn't start: ${e.javaClass.simpleName} ${e.message}")
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    private fun log(line: String) {
        main.post { channel?.invokeMethod("log", line) }
    }

    private fun start(context: Context) {
        if (controller != null) return log("watch: already watching")
        if (browser != null) return log("watch: still connecting")
        log("watch: connecting")
        // Connect like a car would, take the session token, then let go of
        // the service (a bound service would outlive "stop").
        val b = MediaBrowser(
            context,
            ComponentName(context, "com.ryanheise.audioservice.AudioService"),
            object : MediaBrowser.ConnectionCallback() {
                override fun onConnected() {
                    val token = browser?.sessionToken
                    browser?.disconnect()
                    browser = null
                    if (token == null) log("watch: connected without a session")
                    else watch(context, token)
                }

                override fun onConnectionFailed() {
                    browser = null
                    log("watch: couldn't connect to the session")
                }
            },
            null,
        )
        browser = b
        b.connect()
    }

    private fun watch(context: Context, token: MediaSession.Token) {
        val c = MediaController(context, token)
        controller = c
        lastItem = null
        lastState = null
        lastQueue = null
        c.registerCallback(object : MediaController.Callback() {
            override fun onMetadataChanged(metadata: MediaMetadata?) = item(metadata)
            override fun onPlaybackStateChanged(state: PlaybackState?) = state(state)
            override fun onQueueChanged(queue: MutableList<MediaSession.QueueItem>?) = queue()

            override fun onSessionDestroyed() {
                log("watch: session closed")
                controller?.unregisterCallback(this)
                controller = null
                // Never connect again from here: binding would bring the
                // stopped service (and a windowless app) back. The next
                // start of the app asks for a new watch.
            }
        }, main)
        log("watch: started")
        item(c.metadata)
        state(c.playbackState)
        queue()
    }

    private fun item(m: MediaMetadata?) {
        val line = if (m == null) {
            "item none"
        } else {
            val id = m.getString(MediaMetadata.METADATA_KEY_MEDIA_ID) ?: "-"
            val title = m.getString(MediaMetadata.METADATA_KEY_TITLE) ?: "-"
            val artist = m.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: "-"
            val ms = m.getLong(MediaMetadata.METADATA_KEY_DURATION)
            val art = when {
                m.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON) != null -> "picture"
                m.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) != null -> "picture"
                m.getString(MediaMetadata.METADATA_KEY_DISPLAY_ICON_URI) != null -> "link"
                else -> "none"
            }
            "item $id \"$title\" by \"$artist\" ${ms / 1000} s art=$art"
        }
        if (line == lastItem) return
        lastItem = line
        log(line)
    }

    private fun stateName(s: Int) = when (s) {
        PlaybackState.STATE_NONE -> "none"
        PlaybackState.STATE_STOPPED -> "stopped"
        PlaybackState.STATE_PAUSED -> "paused"
        PlaybackState.STATE_PLAYING -> "playing"
        PlaybackState.STATE_FAST_FORWARDING -> "forwarding"
        PlaybackState.STATE_REWINDING -> "rewinding"
        PlaybackState.STATE_BUFFERING -> "buffering"
        PlaybackState.STATE_ERROR -> "error"
        PlaybackState.STATE_CONNECTING -> "connecting"
        PlaybackState.STATE_SKIPPING_TO_PREVIOUS -> "to previous"
        PlaybackState.STATE_SKIPPING_TO_NEXT -> "to next"
        PlaybackState.STATE_SKIPPING_TO_QUEUE_ITEM -> "to queue item"
        else -> "state $s"
    }

    private fun state(p: PlaybackState?) {
        val line = if (p == null) {
            "state none"
        } else {
            // The media id audio_service attaches: the item it had *when this
            // state was sent* (Android Auto matches it to the item).
            val extras = p.extras
            val stateId = extras?.keySet()
                ?.firstOrNull { it.endsWith("KEY_MEDIA_ID") }
                ?.let { extras.getString(it) } ?: "-"
            val active = p.activeQueueItemId
            val activeId = controller?.queue
                ?.firstOrNull { it.queueId == active }
                ?.description?.mediaId ?: "-"
            val error = p.errorMessage?.let { " error=\"$it\"" } ?: ""
            val on = when (ensureActive(p.state)) {
                true -> "yes"
                false -> "no"
                null -> "?"
            }
            // The queue is read now, not when the state was sent.
            "state ${stateName(p.state)} for=$stateId queue#$active=$activeId (queue now) active=$on$error"
        }
        if (line == lastState) return
        lastState = line
        log(line)
    }

    /**
     * Whether audio_service's session is active (null: can't tell), making it
     * active first if music is starting or playing and it isn't.
     *
     * Android Auto waits for the app's session to become active and playing
     * after a tap ("Getting your selection…", then "Could not load your
     * selection"). audio_service makes it active only in enterPlayingState,
     * *after* `startForegroundService`, which Android 12+ may refuse while the
     * app is in the background; the exception is caught and swallowed, the
     * session stays inactive while the music plays, and audio_service never
     * tries again (it already counts itself as playing). This callback runs
     * on the main thread after audio_service's own handling of each state.
     *
     * The session is a private field: reflection, for audio_service 0.18.19
     * (names kept in release builds by proguard-rules.pro).
     */
    private fun ensureActive(state: Int): Boolean? {
        val session = try {
            val cls = Class.forName("com.ryanheise.audioservice.AudioService")
            val service = cls.getDeclaredField("instance").apply { isAccessible = true }.get(null)
                ?: return null
            cls.getDeclaredField("mediaSession").apply { isAccessible = true }.get(service)
                ?: return null
        } catch (e: Exception) {
            if (!reflectionFailed) log("watch: can't see the session: ${e.javaClass.simpleName}")
            reflectionFailed = true
            return null
        }
        return try {
            val active = session.javaClass.getMethod("isActive").invoke(session) as Boolean
            val starting = state == PlaybackState.STATE_PLAYING ||
                state == PlaybackState.STATE_BUFFERING ||
                state == PlaybackState.STATE_CONNECTING
            if (active || !starting) return active
            session.javaClass.getMethod("setActive", Boolean::class.javaPrimitiveType)
                .invoke(session, true)
            log("watch: session was inactive while ${stateName(state)}: made it active")
            true
        } catch (e: Exception) {
            log("watch: couldn't make the session active: ${e.javaClass.simpleName} ${e.message}")
            null
        }
    }

    private var reflectionFailed = false

    private fun queue() {
        val q = controller?.queue
        val line = "queue ${q?.size ?: 0}: first=${q?.firstOrNull()?.description?.mediaId ?: "-"}"
        if (line == lastQueue) return
        lastQueue = line
        log(line)
    }
}
