package org.openmettle.app

import android.app.Activity
import android.app.ActivityManager
import android.content.Intent
import android.os.Bundle

/**
 * Receives the verified HTTPS app link that ends a native sign-in, passes the exact link to the
 * app in memory, brings the app forward and finishes.
 *
 * It is excluded from recents and keeps no history, and it replaces its own intent before doing
 * anything else, so the callback URL is not retained by the activity or the task list. A
 * recreated instance (saved state present) never handles its original intent again.
 */
class NativeAuthCallbackActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val received = intent
        intent = Intent()
        val raw = received?.dataString
        received?.data = null
        val fresh = savedInstanceState == null &&
            ((received?.flags ?: 0) and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0
        val config = NativeAuthHost.config
        if (fresh && received?.action == Intent.ACTION_VIEW && raw != null &&
            config != null && config.isCallback(raw)
        ) {
            NativeAuthHost.offerLink(raw)
        }
        showApp()
        finish()
    }

    private fun showApp() {
        val task = getSystemService(ActivityManager::class.java)?.appTasks?.firstOrNull {
            try {
                it.taskInfo.baseActivity?.className == MainActivity::class.java.name
            } catch (_: IllegalArgumentException) {
                false
            }
        }
        if (task != null) {
            task.moveToFront()
        } else {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .setAction(Intent.ACTION_MAIN)
                    .addCategory(Intent.CATEGORY_LAUNCHER)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }
}
