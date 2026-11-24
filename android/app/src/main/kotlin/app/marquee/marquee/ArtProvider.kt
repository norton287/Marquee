package app.marquee.marquee

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

/**
 * Album art for Android Auto's lists: `content://app.spindlecrank.marquee.art/<file>`.
 *
 * The car can't load server links (and Plex links carry the account token),
 * so the app copies list artwork into `<cache>/car_art` under unguessable
 * names and the car reads it through here. Read only; serves nothing but
 * files directly inside that folder (not the app's general image cache);
 * never touches the network.
 */
class ArtProvider : ContentProvider() {
    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (ParcelFileDescriptor.parseMode(mode) != ParcelFileDescriptor.MODE_READ_ONLY) {
            throw SecurityException("Artwork is read only")
        }
        val name = uri.lastPathSegment ?: throw FileNotFoundException(uri.toString())
        val dir = File(context!!.cacheDir, "car_art").canonicalFile
        val file = File(dir, name).canonicalFile
        if (file.parentFile != dir || !file.isFile) throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    // Saved as .jpg; image decoders read the actual format from the file.
    override fun getType(uri: Uri): String = "image/jpeg"

    override fun query(
        uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(
        uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?,
    ) = 0
}
