package io.github.ccch1mneyyy.dsh_app.runtime

import org.json.JSONObject

internal class OptionalGuestHook {
    private var started = false
    private var stopped = false

    @Synchronized fun start(launch: () -> Unit) {
        if (started || stopped) return
        launch()
        started = true
    }

    @Synchronized fun stop(stop: () -> Unit) {
        stopped = true
        if (started) stop()
    }

    companion object {
        const val path = "/root/feishu-agents/instances/dsh-001/control.sh"
        fun enabled(text: String?): Boolean = try {
            val config = JSONObject(text ?: return false)
            config.keys().asSequence().toSet() == setOf("enabled", "path") &&
                config.opt("enabled") == true && config.opt("path") == path
        } catch (_: Exception) { false }
    }
}
