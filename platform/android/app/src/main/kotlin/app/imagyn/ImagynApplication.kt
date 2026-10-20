package app.imagyn

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * Owns the Flutter engine for the whole process.
 *
 * The activity is only a view onto this engine: swiping the task away detaches
 * that view, and the Dart isolate keeps running while [TurnService] holds the
 * process in the foreground. Reopening the app attaches a new activity to the
 * same engine, so the conversation and the running turn are still there.
 */
class ImagynApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // The constructor registers the generated plugins; the activity must
        // therefore not register them a second time.
        val engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        FlutterEngineCache.getInstance().put(MainActivity.ENGINE_ID, engine)
    }
}
