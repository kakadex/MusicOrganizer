package com.dsh.musicorganizer.musicorganizer

import android.content.Intent
import android.net.Uri
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var pendingPickResult: MethodChannel.Result? = null
    private lateinit var safPlugin: SafPlugin

    private val pickTreeLauncher = registerForActivityResult(
        ActivityResultContracts.OpenDocumentTree()
    ) { uri: Uri? ->
        val result = pendingPickResult
        pendingPickResult = null
        if (uri == null) {
            result?.success(null)
            return@registerForActivityResult
        }
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (_: Exception) {
            // 个别 provider 不支持持久授权：继续，后续访问可能失败
        }
        result?.success(safPlugin.treeInfo(uri))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        safPlugin = SafPlugin(contentResolver)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dsh.musicorganizer/saf"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickTree" -> {
                    pendingPickResult = result
                    pickTreeLauncher.launch(null)
                }
                "listRoots" -> {
                    try {
                        result.success(safPlugin.listRoots())
                    } catch (e: Exception) {
                        result.error("E_IO", e.message, null)
                    }
                }
                "stat" -> {
                    try {
                        val treeUri = call.argument<String>("treeUri") ?: ""
                        val docId = call.argument<String>("docId")
                        result.success(safPlugin.stat(treeUri, docId))
                    } catch (e: SecurityException) {
                        result.error("E_SECURITY", e.message, null)
                    } catch (e: Exception) {
                        result.error("E_IO", e.message, null)
                    }
                }
                "listChildren" -> {
                    try {
                        val treeUri = call.argument<String>("treeUri") ?: ""
                        val parentDocId = call.argument<String>("parentDocId")
                        result.success(safPlugin.listChildren(treeUri, parentDocId))
                    } catch (e: Exception) {
                        result.error("E_IO", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
