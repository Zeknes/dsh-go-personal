package io.github.ccch1mneyyy.dsh_app.runtime

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class OptionalGuestHookTest {
    @Test fun repeatedReadyAndStopBeforeReadyNeverLaunchAnotherOwner() {
        val hook = OptionalGuestHook()
        var starts = 0
        var stops = 0
        repeat(2) { hook.start { starts++ } }
        hook.stop { stops++ }
        hook.start { starts++ }
        assertEquals(1, starts)
        assertEquals(1, stops)
        val cancelled = OptionalGuestHook()
        cancelled.stop { fail("not started") }
        cancelled.start { fail("stopped launch") }
    }

    @Test fun concurrentReadyAndStopAreSerialized() {
        val hook = OptionalGuestHook()
        val entered = java.util.concurrent.CountDownLatch(1)
        val finish = java.util.concurrent.CountDownLatch(1)
        val events = java.util.Collections.synchronizedList(mutableListOf<String>())
        val start = Thread { hook.start { entered.countDown(); finish.await(); events.add("start") } }
        start.start()
        assertTrue(entered.await(2, java.util.concurrent.TimeUnit.SECONDS))
        val stop = Thread { hook.stop { events.add("stop") } }
        stop.start()
        finish.countDown()
        start.join(2000)
        stop.join(2000)
        assertEquals(listOf("start", "stop"), events)
        hook.start { fail("late ready") }
    }

    @Test fun defaultsOffAndAcceptsOnlyTheExplicitManagedHook() {
        assertFalse(OptionalGuestHook.enabled(null))
        assertFalse(OptionalGuestHook.enabled("{}"))
        assertFalse(OptionalGuestHook.enabled("{\"enabled\":false}"))
        assertFalse(OptionalGuestHook.enabled("{\"enabled\":true,\"path\":\"/tmp/other\"}"))
        assertFalse(OptionalGuestHook.enabled("{bad"))
        assertTrue(OptionalGuestHook.enabled("{\"enabled\":true,\"path\":\"/root/feishu-agents/instances/dsh-001/control.sh\"}"))
    }

    @Test fun rejectsUnknownConfigKeysAndNonBooleanValues() {
        assertFalse(OptionalGuestHook.enabled("{\"enabled\":\"true\",\"path\":\"/root/feishu-agents/instances/dsh-001/control.sh\"}"))
        assertFalse(OptionalGuestHook.enabled("{\"enabled\":true,\"path\":\"/root/feishu-agents/instances/dsh-001/control.sh\",\"extra\":true}"))
    }
}
