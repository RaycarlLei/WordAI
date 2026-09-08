package org.wordai.community.word_a_i

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Base64
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleCallback
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.StaleObjectException
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Condition
import androidx.test.uiautomator.textAsString
import androidx.test.uiautomator.uiAutomator
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Native acceptance on an empty emulator. RecordingResult observes the real
 * handler; the picker, URI grant, provider process and descriptor I/O are real.
 * This does not assert a Flutter restore flow or behavior on physical devices.
 */
@RunWith(AndroidJUnit4::class)
class BackupDocumentsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private val resolver get() = instrumentation.targetContext.contentResolver
    private val payload = ("{\"fixture\":\"WordAI synthetic backup\",\"text\":\"" +
        "learning-学习-".repeat(8_000) + "\"}\n").toByteArray(Charsets.UTF_8)

    @Test fun systemPickerCancelCreatesNoDocument() = withApp("cancel") { scenario ->
        val request = begin(scenario, "cancel.json")
        awaitPicker("cancel.json")
        cancelPicker(request.result)
        assertEquals(Outcome(saved = false), request.result.await())
        assertEquals(0, inspect().getInt("created"))
        assertEquals(0, inspect().getInt("writeOpens"))
        assertEquals(1, request.result.values.size)
    }

    @Test fun systemPickerSavesExactBytesAtChosenProvider() = withApp("save") { scenario ->
        val request = begin(scenario, "chosen-location.json")
        awaitPicker("chosen-location.json")
        chooseStorageAndSave()
        assertEquals(Outcome(saved = true), request.result.await())
        val stored = inspect()
        assertEquals(1, stored.getInt("created"))
        assertEquals(1, stored.getInt("writeOpens"))
        assertEquals("chosen-location.json", stored.getString("name"))
        assertArrayEquals(payload, stored.getByteArray("bytes"))
        // Read through the actual URI grant, without adopting shell permissions.
        val uri = Uri.parse(requireNotNull(stored.getString("uri")))
        assertEquals(BackupTestDocumentsProvider.AUTHORITY, uri.authority)
        resolver.openInputStream(uri).use { input ->
            assertArrayEquals(payload, requireNotNull(input).readBytes())
        }
        scenario.onActivity {
            assertFalse(request.handler.onActivityResult(request.code, Activity.RESULT_OK, Intent().setData(uri)))
            assertFalse(request.handler.onActivityResult(request.code, Activity.RESULT_CANCELED, null))
        }
        assertEquals("Duplicate results must not reply again", 1, request.result.values.size)
        assertEquals("Duplicate results must not reopen the document", 1, inspect().getInt("writeOpens"))
    }

    @Test fun providerOpenFailureCannotReportSaved() = withApp("open-failure") { scenario ->
        val request = begin(scenario, "open-failure-fixture.json")
        awaitPicker("open-failure-fixture.json")
        chooseStorageAndSave()
        assertEquals("save_failed", request.result.await().error)
        assertEquals(1, request.result.values.size)
        assertEquals(1, inspect().getInt("writeOpens"))
        assertArrayEquals(byteArrayOf(), inspect().getByteArray("bytes"))
    }

    @Test fun readOnlyProviderDescriptorCannotReportSaved() = withApp("write-failure") { scenario ->
        val request = begin(scenario, "write-failure-fixture.json")
        awaitPicker("write-failure-fixture.json")
        chooseStorageAndSave()
        assertEquals("save_failed", request.result.await().error)
        assertEquals(1, request.result.values.size)
        assertEquals(1, inspect().getInt("writeOpens"))
        assertArrayEquals(byteArrayOf(), inspect().getByteArray("bytes"))
    }

    @Test fun recreateFailsOldRequestAndLateCallbackCannotConsumeNewRequest() = withApp("recreate") { scenario ->
        val old = begin(scenario, "before-recreate.json")
        awaitPicker("before-recreate.json")
        val replaced = CountDownLatch(1)
        val lifecycle = ActivityLifecycleMonitorRegistry.getInstance()
        val listener = ActivityLifecycleCallback { activity, stage ->
            if (activity is MainActivity && stage == Stage.CREATED &&
                activity.backupDocuments != null && activity.backupDocuments !== old.handler) replaced.countDown()
        }
        scenario.onActivity {
            lifecycle.addLifecycleCallback(listener)
            // ActivityScenario.recreate() first forces RESUMED, which cannot
            // happen while DocumentsUI owns the foreground. Recreate the real
            // stopped Activity while its outstanding picker remains open.
            it.recreate()
        }
        try {
            assertEquals("unavailable", old.result.await().error)
            assertTrue("Activity replacement was not observed", replaced.await(UI_TIMEOUT, TimeUnit.MILLISECONDS))
        } finally {
            instrumentation.runOnMainSync { lifecycle.removeLifecycleCallback(listener) }
        }
        // The old picker's real cancellation now reaches the replacement owner.
        dismissPickerToApplication()
        val next = begin(scenario, "after-recreate.json")
        assertNotSame(old.handler, next.handler)
        assertNotEquals(old.code, next.code)
        awaitPicker("after-recreate.json")
        scenario.onActivity {
            assertFalse(old.handler.onActivityResult(old.code, Activity.RESULT_CANCELED, null))
            assertFalse(next.handler.onActivityResult(old.code, Activity.RESULT_OK,
                Intent().setData(Uri.parse("content://${BackupTestDocumentsProvider.AUTHORITY}/document/never-created"))))
            assertEquals(next.code, next.handler.pendingRequestCode)
        }
        assertEquals(1, old.result.values.size)
        assertTrue(next.result.values.isEmpty())
        cancelPicker(next.result)
        assertEquals(Outcome(saved = false), next.result.await())
        assertEquals(1, next.result.values.size)
        assertEquals(0, inspect().getInt("created"))
    }

    @Test fun secondRequestIsRejectedWhileSystemPickerIsPending() = withApp("busy") { scenario ->
        val first = begin(scenario, "first-pending.json")
        awaitPicker("first-pending.json")
        val second = RecordingResult()
        scenario.onActivity {
            first.handler.onMethodCall(saveCall("second-pending.json"), second)
            assertEquals(first.code, first.handler.pendingRequestCode)
        }
        assertEquals("busy", second.await().error)
        assertTrue(first.result.values.isEmpty())
        cancelPicker(first.result)
        assertEquals(Outcome(saved = false), first.result.await())
        assertEquals(1, first.result.values.size)
        assertEquals(0, inspect().getInt("created"))
    }

    @Test fun stalledProviderDeadlineRejectsLateSuccessAndDoesNotAccumulateWriters() = withApp("deadline") { scenario ->
        // This case isolates the real descriptor/deadline path. The other cases
        // prove system-picker grants; only this prepared fixture grants directly.
        val fixture = requireNotNull(resolver.call(CONTROL, "prepare-stall", null, null))
        val id = requireNotNull(fixture.getString("id"))
        val uri = Uri.parse(requireNotNull(fixture.getString("uri")))
        val result = RecordingResult()
        lateinit var handler: BackupDocumentSave
        var code = 0
        scenario.onActivity {
            handler = BackupDocumentSave(it, writeTimeoutMs = 500)
            handler.onMethodCall(saveCall("stall-deadline.json"), result)
            code = requireNotNull(handler.pendingRequestCode)
        }
        try {
            awaitPicker("stall-deadline.json")
            // MainActivity's normal handler does not own this test helper's code.
            dismissPickerToApplication()
            scenario.onActivity { assertTrue(handler.onActivityResult(code, Activity.RESULT_OK, Intent().setData(uri))) }
            resolver.call(CONTROL, "entered", id, null)
            assertEquals("save_failed", result.await().error)
            repeat(3) {
                val blocked = RecordingResult()
                scenario.onActivity { handler.onMethodCall(saveCall("blocked-retry.json"), blocked) }
                assertEquals("busy", blocked.await().error)
            }
            assertEquals(1, inspect().getInt("writeOpens"))
            resolver.call(CONTROL, "release", id, null)
            resolver.call(CONTROL, "drained", id, null)
            var next: RecordingResult? = null
            // Observe the actual writer gate becoming available; no guessed sleep.
            assertTrue(device.wait(object : Condition<UiDevice, Boolean> {
                override fun apply(device: UiDevice): Boolean {
                    val attempt = RecordingResult()
                    scenario.onActivity { handler.onMethodCall(saveCall("after-deadline.json"), attempt) }
                    if (attempt.values.isEmpty()) { next = attempt; return true }
                    assertEquals("busy", attempt.await().error)
                    return false
                }
            }, UI_TIMEOUT))
            awaitPicker("after-deadline.json")
            scenario.onActivity {
                assertFalse(handler.onActivityResult(code, Activity.RESULT_OK, Intent().setData(uri)))
                assertTrue(handler.onActivityResult(requireNotNull(handler.pendingRequestCode), Activity.RESULT_CANCELED, null))
            }
            assertEquals(Outcome(saved = false), requireNotNull(next).await())
            assertEquals("Late provider completion cannot reply again", 1, result.values.size)
            assertEquals("save_failed", result.values.single().error)
            assertEquals(1, inspect().getInt("writeOpens"))
            dismissPickerToApplication()
        } finally {
            resolver.call(CONTROL, "release", id, null)
            scenario.onActivity { handler.detach() }
        }
    }

    private fun begin(scenario: ActivityScenario<MainActivity>, name: String): Request {
        val result = RecordingResult()
        var handler: BackupDocumentSave? = null
        var code: Int? = null
        scenario.onActivity { activity ->
            handler = requireNotNull(activity.backupDocuments)
            handler!!.onMethodCall(saveCall(name), result)
            code = handler!!.pendingRequestCode
        }
        assertTrue("The save must be pending on the real picker", result.values.isEmpty())
        return Request(requireNotNull(handler), requireNotNull(code), result)
    }

    private fun saveCall(name: String) = MethodCall("save", mapOf("bytes" to payload, "suggestedName" to name))

    private fun awaitPicker(name: String) = uiAutomator {
        onElement(UI_TIMEOUT) {
            packageName?.toString()?.endsWith(".documentsui") == true &&
                viewIdResourceName == "android:id/title" &&
                className?.toString() == "android.widget.EditText" && textAsString() == name
        }
    }

    private fun chooseStorageAndSave() = uiAutomator {
        // API 35 DocumentsUI, English emulator. No screen coordinates or sleeps.
        val picker = requireNotNull(device.currentPackageName)
        assertTrue(picker.endsWith(".documentsui"))
        if (onElementOrNull(0) { contentDescription?.toString() == "Show roots" } != null) {
            clickFresh(By.pkg(picker).desc("Show roots"))
        }
        // The drawer rebinds root rows while its provider query completes.
        // Reacquire only a stale object, and only inside the actual roots list.
        clickFresh(By.pkg(picker).text(BackupTestDocumentsProvider.ROOT_TITLE)
            .hasAncestor(By.res(picker, "roots_list")))
        onElement(UI_TIMEOUT) {
            textAsString() == BackupTestDocumentsProvider.ROOT_TITLE &&
                parent?.viewIdResourceName?.endsWith(":id/toolbar") == true
        }
        clickFresh(By.pkg(picker).res("android:id/button1").enabled(true))
    }

    private fun clickFresh(selector: BySelector) {
        assertTrue("Picker control never became actionable", device.wait(object : Condition<UiDevice, Boolean> {
            override fun apply(device: UiDevice): Boolean {
                val element = device.findObject(selector) ?: return false
                return try {
                    element.click()
                    true
                } catch (_: StaleObjectException) {
                    false
                }
            }
        }, UI_TIMEOUT))
    }

    private fun dismissPickerToApplication() {
        val applicationVisible = object : Condition<UiDevice, Boolean> {
            override fun apply(device: UiDevice): Boolean = device.currentPackageName == APP_PACKAGE
        }
        repeat(4) {
            if (applicationVisible.apply(device)) return
            device.pressBack()
            if (device.wait(applicationVisible, 1_000)) return
        }
        fail("DocumentsUI did not return to the application")
    }

    private fun cancelPicker(result: RecordingResult) {
        // Back may first dismiss the filename keyboard. Stop as soon as the
        // Activity result arrives instead of pressing Back in the application.
        repeat(3) {
            if (result.values.isNotEmpty()) return
            device.pressBack()
            if (result.completed.await(500, TimeUnit.MILLISECONDS)) return
        }
        fail("System picker did not deliver cancellation")
    }

    private fun inspect(): Bundle = requireNotNull(resolver.call(CONTROL, "inspect", null, null))

    private fun withApp(label: String, block: (ActivityScenario<MainActivity>) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("wordaiSyntheticEmulatorOnly") == "true")
        check(Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish") {
            "These fixtures are restricted to an empty Android emulator"
        }
        resolver.call(CONTROL, "reset", null, null)
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        try {
            block(scenario)
        } catch (error: Throwable) {
            runCatching {
                // UTP can uninstall the app before the host collects results.
                // Keep only synthetic failure diagnostics in shell-owned tmp.
                val directory = "/data/local/tmp/wordai-backup-test-artifacts"
                device.executeShellCommand("mkdir -p $directory")
                device.executeShellCommand("screencap -p $directory/$label.png")
                val hierarchy = ByteArrayOutputStream()
                device.dumpWindowHierarchy(hierarchy)
                val encoded = Base64.encodeToString(hierarchy.toByteArray(), Base64.NO_WRAP)
                device.executeShellCommand("sh -c 'echo $encoded | base64 -d > $directory/$label.xml'")
            }
            throw error
        } finally {
            scenario.close()
            resolver.call(CONTROL, "reset", null, null)
        }
    }

    private data class Request(val handler: BackupDocumentSave, val code: Int, val result: RecordingResult)
    private data class Outcome(val saved: Boolean? = null, val error: String? = null)
    private class RecordingResult : MethodChannel.Result {
        val values = CopyOnWriteArrayList<Outcome>()
        val completed = CountDownLatch(1)
        override fun success(result: Any?) {
            values.add(Outcome(saved = result as? Boolean))
            completed.countDown()
        }
        override fun error(code: String, message: String?, details: Any?) {
            values.add(Outcome(error = code))
            completed.countDown()
        }
        override fun notImplemented() {
            values.add(Outcome(error = "not_implemented"))
            completed.countDown()
        }
        fun await(): Outcome {
            assertTrue("Native result deadline exceeded", completed.await(UI_TIMEOUT, TimeUnit.MILLISECONDS))
            assertEquals("Native operation replied more than once", 1, values.size)
            return values.single()
        }
    }

    companion object {
        private const val UI_TIMEOUT = 15_000L
        private const val APP_PACKAGE = "org.wordai.community.word_a_i"
        private val CONTROL = Uri.parse("content://org.wordai.community.word_a_i.test.control")
    }
}
