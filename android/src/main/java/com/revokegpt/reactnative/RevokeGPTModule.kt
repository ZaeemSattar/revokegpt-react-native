package com.revokegpt.reactnative

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType
import com.revokegpt.android.Presentation
import com.revokegpt.android.RevokeGPT
import com.revokegpt.android.RevokeGPTException
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The RevokeGPT TurboModule over the native Android SDK (`com.revokegpt:revokegpt-android`), New
 * Architecture only (plan R8). It only translates ([Bridge]): calls go to [RevokeGPT], a
 * challenge sheet is shown on the current Activity, and every failure rejects with an SDK error
 * code, the code again as the message, and a userInfo of the status, the request id and the
 * retry-after seconds only.
 *
 * Calls run in the module's own scope: invalidating the module (a reload, or the React instance
 * going away) cancels them, and they reject with `cancelled`.
 */
class RevokeGPTModule(reactContext: ReactApplicationContext) : NativeRevokeGPTSpec(reactContext) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun configure(config: ReadableMap, promise: Promise) {
        run(promise) {
            val c = readConfig(config)
            RevokeGPT.init(reactApplicationContext, c.siteKey ?: "", Bridge.options(c))
            null
        }
    }

    override fun execute(action: String?, cdata: String?, promise: Promise) {
        run(promise) { RevokeGPT.execute(action, cdata, presentation()) }
    }

    override fun challengeAccount(requestToken: String, languageCode: String?, promise: Promise) {
        run(promise) { RevokeGPT.challengeAccount(requestToken, languageCode, presentation()) }
    }

    override fun invalidate() {
        scope.cancel()
        super.invalidate()
    }

    private fun presentation(): Presentation = Presentation.From { reactApplicationContext.currentActivity }

    /** Settles [promise] exactly once: with [block]'s value, or its rejection. */
    private fun run(promise: Promise, block: suspend () -> String?) {
        val settled = AtomicBoolean(false)
        scope.launch {
            val result = Bridge.settle(scope, block)
            if (!settled.compareAndSet(false, true)) return@launch
            result.fold(
                onSuccess = { promise.resolve(it) },
                onFailure = { reject(promise, (it as Bridge.Rejected).rejection) },
            )
        }.invokeOnCompletion { cause ->
            // Cancelled before settle ran (the module was invalidated first).
            if (cause != null && settled.compareAndSet(false, true)) reject(promise, Bridge.rejection(cause))
        }
    }

    private fun reject(promise: Promise, r: Bridge.Rejection) {
        val userInfo = Arguments.createMap()
        for ((k, v) in r.details) {
            when (v) {
                is Int -> userInfo.putInt(k, v)
                is String -> userInfo.putString(k, v)
            }
        }
        promise.reject(r.code, r.code, userInfo)
    }

    private companion object {
        /**
         * The configuration as JavaScript sent it: an absent or null field is null, a field of
         * the wrong type is `invalid-argument` (the JavaScript layer refuses both first).
         */
        fun readConfig(m: ReadableMap) = Bridge.Config(
            siteKey = m.string("siteKey"),
            endpoint = m.string("endpoint"),
            widgetOrigin = m.string("widgetOrigin"),
            timeoutMs = if (m.present("timeoutMs", ReadableType.Number)) m.getDouble("timeoutMs") else null,
            cloudProjectNumber = m.string("cloudProjectNumber"),
            locale = m.string("locale"),
            theme = m.string("theme"),
            // keyScope is iOS-only (an App Attest key per account); only its type is checked here.
            keyScope = m.string("keyScope"),
            debugLogging = if (m.present("debugLogging", ReadableType.Boolean)) m.getBoolean("debugLogging") else null,
        )

        /** Whether [key] holds a value of [type]; false when absent or null; else invalid. */
        fun ReadableMap.present(key: String, type: ReadableType): Boolean {
            if (!hasKey(key) || getType(key) == ReadableType.Null) return false
            if (getType(key) != type) throw RevokeGPTException("invalid-argument")
            return true
        }

        fun ReadableMap.string(key: String) = if (present(key, ReadableType.String)) getString(key) else null
    }
}
