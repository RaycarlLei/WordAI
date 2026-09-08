package org.wordai.community.word_a_i

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** One Activity's pending picker/write. Call its methods on the main thread. */
internal class BackupDocumentSave(
    private val activity: Activity,
    private val writeTimeoutMs: Long = 30_000,
) : MethodChannel.MethodCallHandler {
    private class Request(
        val code: Int,
        val bytes: ByteArray,
        val result: MethodChannel.Result,
        val cancelled: AtomicBoolean = AtomicBoolean(false),
        var writing: Boolean = false,
        var deadline: Runnable? = null,
    )

    private val main = Handler(Looper.getMainLooper())
    private var pending: Request? = null
    private var detached = false
    internal val pendingRequestCode: Int? get() = pending?.code

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "save") {
            result.notImplemented()
            return
        }
        if (detached || activity.isFinishing || activity.isDestroyed) {
            result.error("unavailable", "The file operation was interrupted.", null)
            return
        }
        if (pending != null || BackupDocumentIo.isBusy) {
            result.error("busy", "Finish the current file operation first.", null)
            return
        }
        val arguments = call.arguments as? Map<*, *>
        val bytes = arguments?.get("bytes") as? ByteArray
        val name = arguments?.get("suggestedName") as? String
        if (bytes == null || bytes.isEmpty() || bytes.size > MAX_BYTES) {
            result.error("invalid_data", "Invalid backup size.", null)
            return
        }
        if (name == null || !validName(name)) {
            result.error("invalid_name", "Invalid backup filename.", null)
            return
        }
        // Never reuse a code in this process: a destroyed Activity's delayed
        // picker result must not be accepted as a new request's destination.
        val code = requestCodes.getAndIncrement()
        if (code > 0xffff) {
            result.error("unavailable", "Reopen the app to save a backup.", null)
            return
        }
        val request = Request(code, bytes.copyOf(), result)
        pending = request
        try {
            activity.startActivityForResult(
                Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/json"
                    putExtra(Intent.EXTRA_TITLE, name)
                },
                code,
            )
        } catch (_: Exception) {
            fail(request, "unavailable")
        }
    }

    internal fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        val request = pending
        if (request == null || request.code != code) return false
        if (request.writing) return true
        if (resultCode == Activity.RESULT_CANCELED) {
            finish(request, false)
            return true
        }
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || uri.scheme != "content") {
            fail(request, "save_failed")
            return true
        }
        request.writing = true
        val expiresAt = SystemClock.elapsedRealtime() + writeTimeoutMs
        val deadline = Runnable {
            request.cancelled.set(true)
            fail(request, "save_failed")
        }
        request.deadline = deadline
        main.postDelayed(deadline, writeTimeoutMs)
        val accepted = BackupDocumentIo.submit {
            val succeeded = try {
                BackupDocumentWriter.write(
                    activity.applicationContext.contentResolver,
                    uri,
                    request.bytes,
                    request.cancelled,
                )
                true
            } catch (_: Exception) {
                false
            }
            main.post {
                if (succeeded && !request.cancelled.get() && SystemClock.elapsedRealtime() < expiresAt) finish(request, true)
                else fail(request, "save_failed")
            }
        }
        if (!accepted) fail(request, "busy")
        return true
    }

    internal fun detach() {
        if (detached) return
        detached = true
        pending?.let {
            it.cancelled.set(true)
            fail(it, "unavailable")
        }
    }

    private fun finish(request: Request, saved: Boolean) {
        if (pending !== request) return
        pending = null
        request.deadline?.let(main::removeCallbacks)
        request.result.success(saved)
    }

    private fun fail(request: Request, code: String) {
        if (pending !== request) return
        pending = null
        request.deadline?.let(main::removeCallbacks)
        request.result.error(code, "The backup was not confirmed saved. A partial file may remain.", null)
    }

    companion object {
        private const val MAX_BYTES = 32 * 1024 * 1024
        private val requestCodes = AtomicInteger(0x6200)
        private val namePattern = Regex("^[A-Za-z0-9][A-Za-z0-9._-]*\\.json$")
        private val reserved = Regex("^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$", RegexOption.IGNORE_CASE)

        private fun validName(name: String): Boolean =
            name.length <= 128 && namePattern.matches(name) &&
                !name.contains("..") && !reserved.matches(name.substringBefore('.'))
    }
}

/** The provider owns the chosen document. Never delete it, even on failure. */
internal object BackupDocumentWriter {
    internal fun write(resolver: ContentResolver, uri: Uri, bytes: ByteArray, cancelled: AtomicBoolean) {
        fun checkActive() {
            if (cancelled.get()) throw IOException("Backup write interrupted")
        }
        checkActive()
        val output = resolver.openOutputStream(uri, "wt") ?: throw IOException("No document stream")
        output.use {
            var offset = 0
            while (offset < bytes.size) {
                checkActive()
                val count = minOf(64 * 1024, bytes.size - offset)
                it.write(bytes, offset, count)
                offset += count
            }
            checkActive()
            it.flush()
        }
        // Closing can fail or finish after the Activity/deadline was invalidated.
        checkActive()
    }
}

/** A stuck provider must not accumulate a new thread for every retry/Activity. */
private object BackupDocumentIo {
    private val busy = AtomicBoolean(false)
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "wordai-backup-writer").apply { isDaemon = true }
    }
    val isBusy: Boolean get() = busy.get()

    fun submit(action: () -> Unit): Boolean {
        if (!busy.compareAndSet(false, true)) return false
        try {
            worker.execute {
                try { action() } finally { busy.set(false) }
            }
        } catch (_: Exception) {
            busy.set(false)
            return false
        }
        return true
    }
}
