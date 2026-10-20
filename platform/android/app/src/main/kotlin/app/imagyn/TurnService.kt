package app.imagyn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder

/**
 * Keeps the process in the foreground while a turn runs.
 *
 * It runs no work itself — the Dart isolate does — but a foreground service is
 * what stops Android from reaping the process when the task is swiped away.
 * The notification is deliberately quiet: it is a status line, not an alert.
 */
class TurnService : Service() {
    companion object {
        private const val RUNNING = "imagyn.turn"
        private const val DONE = "imagyn.done"
        private const val RUNNING_ID = 1201
        private const val DONE_ID = 1202

        fun start(context: Context, title: String, body: String) {
            ensureChannels(context)
            val intent = Intent(context, TurnService::class.java)
                .putExtra("title", title)
                .putExtra("body", body)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TurnService::class.java))
        }

        fun notify(context: Context, title: String, body: String) {
            if (Build.VERSION.SDK_INT >= 33 &&
                context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
            ensureChannels(context)
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(DONE_ID, notification(context, DONE, title, body, false))
        }

        private fun ensureChannels(context: Context) {
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(RUNNING) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        RUNNING,
                        "Imagyn task",
                        NotificationManager.IMPORTANCE_LOW,
                    )
                )
            }
            if (manager.getNotificationChannel(DONE) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        DONE,
                        "Imagyn results",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    )
                )
            }
        }

        private fun notification(
            context: Context,
            channel: String,
            title: String,
            body: String,
            ongoing: Boolean,
        ): Notification =
            Notification.Builder(context, channel)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setOngoing(ongoing)
                .setOnlyAlertOnce(ongoing)
                .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra("title") ?: "Imagyn"
        val body = intent?.getStringExtra("body") ?: ""
        startForeground(RUNNING_ID, notification(this, RUNNING, title, body, true))
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
