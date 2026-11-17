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
import io.flutter.embedding.engine.FlutterEngine
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
    private var engine: FlutterEngine? = null
    private var controller: MediaController? = null
    private var browser: MediaBrowser? = null
    private var lastItem: String? = null
    private var lastState: String? = null
    private var lastQueue: String? = null

    /**
     * Talks to [engine]'s Dart from now on. audio_service throws its engine
     * away when the service ends and makes a new one on the next start (the
     * process may live on), so every engine is attached, newest wins.
     */
    fun attach(context: Context, engine: FlutterEngine) {
        if (this.engine === engine) return
        this.engine = engine
        val app = context.applicationContext
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                if (call.method == "start") {
                    start(app)
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
        if (controller != null || browser != null) return
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
                    if (token != null) watch(context, token)
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
            // The queue is read now, not when the state was sent.
            "state ${stateName(p.state)} for=$stateId queue#$active=$activeId (queue now)$error"
        }
        if (line == lastState) return
        lastState = line
        log(line)
    }

    private fun queue() {
        val q = controller?.queue
        val line = "queue ${q?.size ?: 0}: first=${q?.firstOrNull()?.description?.mediaId ?: "-"}"
        if (line == lastQueue) return
        lastQueue = line
        log(line)
    }
}
