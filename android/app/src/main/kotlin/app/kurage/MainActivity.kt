package app.kurage

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private val audio by lazy { getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    private val maxVolume get() = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
    private val volume get() = audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / maxVolume

    // The page's end is the Flutter engine's, but Android may keep the process
    // for the next launch, with any video player still running in it. Such a
    // player calls back into the engine that's gone, and crashes the app (seen
    // on reopening). Nothing here outlives the page, so the process goes too.
    override fun onDestroy() {
        super.onDestroy()
        if (!isChangingConfigurations) android.os.Process.killProcess(android.os.Process.myPid())
    }

    private var pendingSaveText: String? = null
    private var pendingSaveResult: MethodChannel.Result? = null

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SAVE_FILE_REQUEST) return
        val result = pendingSaveResult ?: return
        val text = pendingSaveText
        pendingSaveResult = null
        pendingSaveText = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null || text == null) {
            result.success(false)
            return
        }
        try {
            contentResolver.openOutputStream(uri)?.use { it.write(text.toByteArray()) }
            result.success(true)
        } catch (e: Exception) {
            result.error("save", e.message, null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // Volume / brightness for the player's swipe gestures (0.0–1.0).
        MethodChannel(messenger, "jellyfin_client/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "getVolume" -> result.success(volume)
                "setVolume" -> {
                    val value = (call.arguments as Double).coerceIn(0.0, 1.0)
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, (value * maxVolume).roundToInt(), 0)
                    result.success(null)
                }
                "getBrightness" -> {
                    // The window's own level, else the system setting.
                    val window = window.attributes.screenBrightness
                    result.success(
                        if (window >= 0) window.toDouble()
                        else Settings.System.getInt(
                            contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128,
                        ) / 255.0,
                    )
                }
                "setBrightness" -> {
                    val value = (call.arguments as Double).coerceIn(0.01, 1.0)
                    window.attributes = window.attributes.apply { screenBrightness = value.toFloat() }
                    result.success(null)
                }
                "resetBrightness" -> {
                    window.attributes = window.attributes.apply {
                        screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                    }
                    result.success(null)
                }
                "canInstallApks" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls(),
                )
                // An in-app update: opens Android's installer on the APK, or
                // first the page to allow installs from this app.
                "installApk" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                        startActivity(
                            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")),
                        )
                        result.success("permission")
                    } else {
                        val apk = File(call.arguments as String)
                        val uri = FileProvider.getUriForFile(this, "$packageName.updates", apk)
                        startActivity(
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success("started")
                    }
                }
                // Saving a text file where the person chooses.
                "saveTextFile" -> {
                    pendingSaveText = call.argument<String>("text")
                    pendingSaveResult = result
                    startActivityForResult(
                        Intent(Intent.ACTION_CREATE_DOCUMENT)
                            .addCategory(Intent.CATEGORY_OPENABLE)
                            .setType("application/json")
                            .putExtra(Intent.EXTRA_TITLE, call.argument<String>("name")),
                        SAVE_FILE_REQUEST,
                    )
                }
                else -> result.notImplemented()
            }
        }

        // Media volume changes from anywhere (volume keys, other apps), so the
        // swipe level stays in step with what the phone plays at.
        EventChannel(messenger, "jellyfin_client/volume").setStreamHandler(object : EventChannel.StreamHandler {
            private var receiver: BroadcastReceiver? = null

            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                receiver = object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        val stream = intent.getIntExtra("android.media.EXTRA_VOLUME_STREAM_TYPE", -1)
                        if (stream == AudioManager.STREAM_MUSIC) events.success(volume)
                    }
                }
                val filter = IntentFilter("android.media.VOLUME_CHANGED_ACTION")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
                } else {
                    registerReceiver(receiver, filter)
                }
            }

            override fun onCancel(arguments: Any?) {
                receiver?.let { unregisterReceiver(it) }
                receiver = null
            }
        })
    }

    private companion object {
        const val SAVE_FILE_REQUEST = 4101
    }
}
