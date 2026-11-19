package com.revokegpt.reactnative

import com.revokegpt.android.RevokeGPTException
import com.revokegpt.android.RevokeGPTOptions
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ensureActive

/**
 * The module's translation, free of React Native types so JUnit covers it: the configuration
 * JavaScript sends becomes [RevokeGPTOptions], and every failure becomes a [Rejection].
 */
internal object Bridge {
    /** The package version, in lockstep with the native SDKs (plan R7). */
    const val VERSION: String = "0.1.1"

    /** Names this package in the `sdk` field (plan R10). */
    val wrapper: RevokeGPTOptions.Wrapper = RevokeGPTOptions.Wrapper("revokegpt-react-native", VERSION)

    /** What JavaScript sent to `configure`, each optional field null when absent. */
    data class Config(
        val siteKey: String?,
        val endpoint: String? = null,
        val widgetOrigin: String? = null,
        val timeoutMs: Double? = null,
        val cloudProjectNumber: String? = null,
        val locale: String? = null,
        val theme: String? = null,
        /** iOS only; ignored here (Play Integrity keeps no per-app key). */
        val keyScope: String? = null,
        val debugLogging: Boolean? = null,
    )

    /**
     * A rejection: an SDK error code (protocol v1 section 23.3) and only the status, the request
     * id and the retry-after seconds, each only when present. No message, no lower layer's text.
     */
    data class Rejection(val code: String, val details: Map<String, Any>)

    /** The native options; a field the SDK cannot take is `invalid-argument`. */
    fun options(c: Config): RevokeGPTOptions {
        val timeout = c.timeoutMs?.let {
            if (!it.isFinite() || it != Math.rint(it) || it !in 1_000.0..60_000.0) throw invalid()
            it.toLong()
        } ?: 10_000L
        val project = c.cloudProjectNumber?.let {
            if (!PROJECT_NUMBER.matches(it)) throw invalid()
            it.toLongOrNull() ?: throw invalid()
        }
        val theme = when (c.theme) {
            null, "auto" -> RevokeGPTOptions.Theme.AUTO
            "light" -> RevokeGPTOptions.Theme.LIGHT
            "dark" -> RevokeGPTOptions.Theme.DARK
            else -> throw invalid()
        }
        return RevokeGPTOptions(
            endpoint = c.endpoint ?: RevokeGPTOptions.DEFAULT_ENDPOINT,
            widgetOrigin = c.widgetOrigin ?: RevokeGPTOptions.DEFAULT_WIDGET_ORIGIN,
            timeoutMillis = timeout,
            cloudProjectNumber = project,
            locale = c.locale,
            theme = theme,
            debugLogging = c.debugLogging ?: false,
            wrapper = wrapper,
        )
    }

    /**
     * A [RevokeGPTException] keeps its code (an unknown one becomes `internal`) and details; a
     * cancellation (the module was invalidated) is `cancelled`, as a cancelled call is on iOS and
     * in the Flutter plugin; anything else is `internal`.
     */
    fun rejection(t: Throwable): Rejection {
        val e = when (t) {
            is RevokeGPTException -> t
            is CancellationException -> RevokeGPTException("cancelled")
            else -> RevokeGPTException("internal")
        }
        if (e.code !in RevokeGPTException.CODES) return Rejection("internal", emptyMap())
        val details = buildMap<String, Any> {
            if (e.status != 0) put("status", e.status)
            e.requestId?.let { put("requestId", it) }
            e.retryAfterSeconds?.let { put("retryAfterSeconds", it) }
        }
        return Rejection(e.code, details)
    }

    /**
     * Runs [block] (the caller runs this in [scope], so invalidating the module cancels it; a
     * cancelled [scope] runs nothing) and returns its value, or
     * the [Rejection] for whatever it threw. Never throws, so nothing reaches React Native's own
     * error handling, which would pass an exception's message to JavaScript.
     */
    suspend fun <T> settle(scope: CoroutineScope, block: suspend () -> T): Result<T> = try {
        scope.ensureActive()
        Result.success(block())
    } catch (t: Throwable) {
        Result.failure(Rejected(rejection(t)))
    }

    /** The failure [settle] returns. */
    class Rejected(val rejection: Rejection) : Exception(rejection.code)

    private fun invalid() = RevokeGPTException("invalid-argument")

    /** A Google Cloud project number: 1 to 19 digits, no leading zero (a positive `Long`). */
    private val PROJECT_NUMBER = Regex("^[1-9][0-9]{0,18}$")
}
