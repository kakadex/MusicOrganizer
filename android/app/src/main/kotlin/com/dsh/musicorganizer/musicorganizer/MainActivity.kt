package com.dsh.musicorganizer.musicorganizer

import android.app.Activity
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var pendingPickResult: MethodChannel.Result? = null
    private lateinit var safPlugin: SafPlugin

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
                    startActivityForResult(
                        Intent(Intent.ACTION_OPEN_DOCUMENT_TREE),
                        REQUEST_CODE_OPEN_TREE
                    )
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

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CODE_OPEN_TREE) return
        val result = pendingPickResult
        pendingPickResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result?.success(null)
            return
        }
        val uri: Uri = data.data!!
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

    companion object {
        private const val REQUEST_CODE_OPEN_TREE = 4401
    }
}
