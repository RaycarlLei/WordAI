package org.wordai.community.word_a_i

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent

class MainActivity : FlutterActivity() {
    internal var backupDocuments: BackupDocumentSave? = null
        private set
    private var backupChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        backupDocuments?.detach()
        backupDocuments = BackupDocumentSave(this)
        backupChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.wordai.community/backup_files",
        ).also { it.setMethodCallHandler(backupDocuments) }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (backupDocuments?.onActivityResult(requestCode, resultCode, data) != true) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        backupDocuments?.detach()
        backupChannel?.setMethodCallHandler(null)
        backupChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        backupDocuments?.detach()
        super.onDestroy()
    }
}
