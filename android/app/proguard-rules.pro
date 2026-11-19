# CarWatch.kt reads audio_service's media session by reflection (to make it
# active when audio_service's own start failed); keep the names it looks up.
-keepclassmembers class com.ryanheise.audioservice.AudioService {
    static com.ryanheise.audioservice.AudioService instance;
    private android.support.v4.media.session.MediaSessionCompat mediaSession;
}
-keepclassmembers class android.support.v4.media.session.MediaSessionCompat {
    public boolean isActive();
    public void setActive(boolean);
}
