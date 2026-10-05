package com.alu.alu_tracker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NotificationManager::class.java)
            val alarm = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            val sos = NotificationChannel("sos", "Emergency", NotificationManager.IMPORTANCE_HIGH)
            sos.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM), alarm)
            sos.enableVibration(true)
            sos.vibrationPattern = longArrayOf(0, 800, 200, 800, 200, 800, 200, 800)
            sos.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            val miss = NotificationChannel("miss", "Miss you", NotificationManager.IMPORTANCE_HIGH)
            miss.enableVibration(true)
            miss.vibrationPattern = longArrayOf(0, 200, 100, 200, 100, 400)
            nm.createNotificationChannels(listOf(sos, miss))
        }
    }
}
