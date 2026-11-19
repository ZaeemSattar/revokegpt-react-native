package com.revokegpt.reactnative

import com.revokegpt.android.RevokeGPTException
import com.revokegpt.android.RevokeGPTOptions
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** The module's reject codes and details, and its configuration mapping ([Bridge]). */
class ModuleTest {
    private fun rejected(r: Result<*>): Bridge.Rejection {
        assertTrue("expected a failure, got $r", r.isFailure)
        return (r.exceptionOrNull() as Bridge.Rejected).rejection
    }

    @Test
    fun anApiErrorKeepsItsCodeAndOnlyItsThreeDetails() {
        val r = Bridge.rejection(RevokeGPTException("rate-limited", 429, "req_1.a:b-c", 30))
        assertEquals("rate-limited", r.code)
        assertEquals(mapOf("status" to 429, "requestId" to "req_1.a:b-c", "retryAfterSeconds" to 30), r.details)
    }

    @Test
    fun everyOwnAndApiCodePassesThrough() {
        assertEquals(27, RevokeGPTException.CODES.size)
        for (code in RevokeGPTException.CODES) {
            assertEquals(code, Bridge.rejection(RevokeGPTException(code)).code)
        }
    }

    @Test
    fun anHttpErrorWithoutARequestIdOmitsIt() {
        val r = Bridge.rejection(RevokeGPTException("http-error", 503, null, 120))
        assertEquals("http-error", r.code)
        assertEquals(mapOf("status" to 503, "retryAfterSeconds" to 120), r.details)
    }

    @Test
    fun anErrorWithoutDetailsHasNone() {
        val r = Bridge.rejection(RevokeGPTException("network-error"))
        assertEquals("network-error", r.code)
        assertEquals(emptyMap<String, Any>(), r.details)
    }

    @Test
    fun anUnknownCodeBecomesInternalWithNoDetails() {
        val r = Bridge.rejection(RevokeGPTException("not-a-code", 418, "req", 5))
        assertEquals(Bridge.Rejection("internal", emptyMap()), r)
    }

    @Test
    fun aCancellationIsCancelled() {
        assertEquals(Bridge.Rejection("cancelled", emptyMap()), Bridge.rejection(CancellationException("x")))
    }

    @Test
    fun anyOtherThrowableIsInternalAndCarriesNoText() {
        val r = Bridge.rejection(IllegalStateException("secret rgpk_00000000000000000000"))
        assertEquals(Bridge.Rejection("internal", emptyMap()), r)
        assertFalse(r.toString().contains("secret"))
    }

    @Test
    fun settleReturnsTheValue() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        assertEquals("token", Bridge.settle(scope) { "token" }.getOrThrow())
        scope.cancel()
    }

    @Test
    fun settleTurnsAThrowIntoItsRejection() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val r = rejected(Bridge.settle(scope) { throw RevokeGPTException("busy") })
        assertEquals("busy", r.code)
        val i = rejected(Bridge.settle(scope) { error("boom") })
        assertEquals("internal", i.code)
        scope.cancel()
    }

    @Test
    fun invalidatingTheModuleCancelsACallInFlight() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val started = CompletableDeferred<Unit>()
        val never = CompletableDeferred<String>()
        // As the module runs a call: launched in its scope, the result handed out of it.
        val result = CompletableDeferred<Result<String>>()
        scope.launch {
            result.complete(
                Bridge.settle(scope) {
                    started.complete(Unit)
                    never.await()
                },
            )
        }
        withTimeout(5_000) { started.await() }
        scope.cancel()
        val r = rejected(withTimeout(5_000) { result.await() })
        assertEquals(Bridge.Rejection("cancelled", emptyMap()), r)
        assertFalse(never.isCompleted)
    }

    @Test
    fun aCallAfterInvalidationIsCancelledWithoutRunning() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        scope.cancel()
        var ran = false
        val r = rejected(Bridge.settle(scope) { ran = true; "token" })
        assertEquals("cancelled", r.code)
        assertFalse(ran)
    }

    @Test
    fun theDefaultsNameThePackageInTheSdkField() {
        val o = Bridge.options(Bridge.Config(siteKey = "rgpk_00000000000000000000"))
        assertEquals(RevokeGPTOptions.DEFAULT_ENDPOINT, o.endpoint)
        assertEquals(RevokeGPTOptions.DEFAULT_WIDGET_ORIGIN, o.widgetOrigin)
        assertEquals(10_000L, o.timeoutMillis)
        assertEquals(null, o.cloudProjectNumber)
        assertEquals(null, o.locale)
        assertEquals(RevokeGPTOptions.Theme.AUTO, o.theme)
        assertFalse(o.debugLogging)
        assertSame(Bridge.wrapper, o.wrapper)
        assertEquals("revokegpt-react-native", o.wrapper?.name)
        assertEquals("0.1.1", o.wrapper?.version)
    }

    @Test
    fun everyFieldIsPassedThrough() {
        val o = Bridge.options(
            Bridge.Config(
                siteKey = "rgpk_00000000000000000000",
                endpoint = "https://api.example.com/rg",
                widgetOrigin = "https://js.example.com",
                timeoutMs = 60_000.0,
                cloudProjectNumber = "9223372036854775807",
                locale = "pt-BR",
                theme = "dark",
                debugLogging = true,
            ),
        )
        assertEquals("https://api.example.com/rg", o.endpoint)
        assertEquals("https://js.example.com", o.widgetOrigin)
        assertEquals(60_000L, o.timeoutMillis)
        assertEquals(Long.MAX_VALUE, o.cloudProjectNumber)
        assertEquals("pt-BR", o.locale)
        assertEquals(RevokeGPTOptions.Theme.DARK, o.theme)
        assertTrue(o.debugLogging)
        assertEquals(RevokeGPTOptions.Theme.LIGHT, Bridge.options(Bridge.Config("k", theme = "light")).theme)
    }

    @Test
    fun aMalformedFieldIsInvalidArgument() {
        val bad = listOf(
            Bridge.Config("k", timeoutMs = 999.0),
            Bridge.Config("k", timeoutMs = 60_001.0),
            Bridge.Config("k", timeoutMs = 1_500.5),
            Bridge.Config("k", timeoutMs = Double.NaN),
            Bridge.Config("k", timeoutMs = Double.POSITIVE_INFINITY),
            Bridge.Config("k", cloudProjectNumber = "0"),
            Bridge.Config("k", cloudProjectNumber = "0123"),
            Bridge.Config("k", cloudProjectNumber = "-5"),
            Bridge.Config("k", cloudProjectNumber = "12a"),
            Bridge.Config("k", cloudProjectNumber = "9223372036854775808"),
            Bridge.Config("k", cloudProjectNumber = ""),
            Bridge.Config("k", theme = "blue"),
            Bridge.Config("k", theme = "Dark"),
        )
        for (c in bad) {
            val e = assertThrows(c.toString(), RevokeGPTException::class.java) { Bridge.options(c) }
            assertEquals("invalid-argument", e.code)
        }
    }
}
