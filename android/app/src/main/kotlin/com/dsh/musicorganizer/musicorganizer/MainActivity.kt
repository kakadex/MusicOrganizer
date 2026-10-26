package com.dsh.musicorganizer.musicorganizer

import android.app.Activity
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException

class MainActivity : FlutterActivity() {

    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private lateinit var safPlugin: SafPlugin
    private var hostChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        safPlugin = SafPlugin(contentResolver)
        // 宿主能力：任务通知（前台服务）+ 外部调起拿到的文件
        val host = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dsh.musicorganizer/host"
        )
        hostChannel = host
        host.setMethodCallHandler { call, result ->
            when (call.method) {
                "updateTask" -> {
                    val intent = Intent(this, TaskForegroundService::class.java).apply {
                        putExtra(TaskForegroundService.EXTRA_TITLE, call.argument<String>("title") ?: "正在处理")
                        putExtra(TaskForegroundService.EXTRA_TEXT, call.argument<String>("text") ?: "")
                        putExtra(TaskForegroundService.EXTRA_DONE, call.argument<Int>("done") ?: 0)
                        putExtra(TaskForegroundService.EXTRA_TOTAL, call.argument<Int>("total") ?: 0)
                    }
                    runCatching { startForegroundServiceCompat(intent) }
                    result.success(null)
                }
                "stopTask" -> {
                    runCatching {
                        stopService(Intent(this, TaskForegroundService::class.java))
                    }
                    result.success(null)
                }
                "takeInitialIntent" -> result.success(initialFileUri)
                "uriInfo" -> safCall(result) {
                    safPlugin.uriInfo(call.argument<String>("uri") ?: "")
                }
                else -> result.notImplemented()
            }
        }
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
                "listRoots" -> safCall(result) { safPlugin.listRoots() }
                "stat" -> safCall(result) {
                    safPlugin.stat(call.argument<String>("treeUri") ?: "", call.argument<String>("docId"))
                }
                "listChildren" -> safCall(result) {
                    safPlugin.listChildren(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("parentDocId")
                    )
                }
                "copyDocToCache" -> safCall(result) {
                    safPlugin.copyDocToCache(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: "",
                        call.argument<String>("cachePath") ?: "",
                        call.argument<Int>("maxBytes") ?: 0
                    )
                }
                "writeCacheToDoc" -> safCall(result) {
                    safPlugin.writeCacheToDoc(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: "",
                        call.argument<String>("cachePath") ?: ""
                    )
                }
                "readHead" -> safCall(result) {
                    safPlugin.readHead(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: "",
                        call.argument<Int>("maxBytes") ?: 0
                    )
                }
                "readTail" -> safCall(result) {
                    safPlugin.readTail(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: "",
                        call.argument<Int>("maxBytes") ?: 0
                    )
                }
                "createDocument" -> safCall(result) {
                    safPlugin.createDocument(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("parentDocId") ?: "",
                        call.argument<String>("name") ?: "",
                        call.argument<String>("mime") ?: "application/octet-stream"
                    )
                }
                "createDir" -> safCall(result) {
                    safPlugin.createDir(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("parentDocId") ?: "",
                        call.argument<String>("name") ?: ""
                    )
                }
                "deleteDocument" -> safCall(result) {
                    safPlugin.deleteDocument(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: ""
                    )
                }
                "renameDocument" -> safCall(result) {
                    safPlugin.renameDocument(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: "",
                        call.argument<String>("newName") ?: ""
                    )
                }
                "moveDocument" -> safCall(result) {
                    safPlugin.moveDocument(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: "",
                        call.argument<String>("sourceParentDocId"),
                        call.argument<String>("targetParentDocId") ?: ""
                    )
                }
                "mediaScan" -> {
                    try {
                        val paths = call.argument<List<String>>("paths") ?: emptyList()
                        if (paths.isNotEmpty()) {
                            MediaScannerConnection.scanFile(this, paths.toTypedArray(), null, null)
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("E_IO", e.message, null)
                    }
                }
                "mediaStoreAudio" -> safCall(result) {
                    safPlugin.mediaStoreAudio(call.argument<Int>("minDurationMs") ?: 0)
                }
                "copyMediaToCache" -> safCall(result) {
                    safPlugin.copyMediaToCache(
                        call.argument<String>("uri") ?: "",
                        call.argument<String>("cachePath") ?: ""
                    )
                }
                "requestAudioPermission" -> requestAudioPermission(result)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 外部调起带进来的文件 URI（ACTION_EDIT / ACTION_VIEW）。
     *
     * 用户在文件管理器里「用本应用打开」音频时，把它交给 Dart 侧直接进编辑器；
     * 应用已经在前台时走 [onNewIntent]，同样转发过去。
     */
    private var initialFileUri: String? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        initialFileUri = fileUriFrom(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val uri = fileUriFrom(intent)
        if (uri.isNullOrEmpty()) return
        initialFileUri = uri
        hostChannel?.invokeMethod("onFileIntent", uri)
    }

    private fun fileUriFrom(intent: Intent?): String? {
        val intent = intent ?: return null
        val action = intent.action
        if (action != Intent.ACTION_EDIT && action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        // 只读一次授权，避免重启后失效
        runCatching {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        }
        return uri.toString()
    }

    private fun startForegroundServiceCompat(intent: Intent) {
        if (android.os.Build.VERSION.SDK_INT >= 26) startForegroundService(intent)
        else startService(intent)
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

    /**
     * 申请读取音频的权限（只在用户明确要导入系统媒体库时才申请）。
     *
     * 安卓 13+ 要 READ_MEDIA_AUDIO，更早的版本要 READ_EXTERNAL_STORAGE。
     */
    private fun requestAudioPermission(result: MethodChannel.Result) {
        val permission = if (android.os.Build.VERSION.SDK_INT >= 33) {
            "android.permission.READ_MEDIA_AUDIO"
        } else {
            "android.permission.READ_EXTERNAL_STORAGE"
        }
        if (checkSelfPermission(permission) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        pendingPermissionResult = result
        requestPermissions(arrayOf(permission), REQUEST_CODE_AUDIO_PERMISSION)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CODE_AUDIO_PERMISSION) return
        val result = pendingPermissionResult
        pendingPermissionResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
        result?.success(granted)
    }

    private fun safCall(result: MethodChannel.Result, block: () -> Any?) {
        try {
            result.success(block())
        } catch (e: SecurityException) {
            result.error("E_NO_PERMISSION", e.message, null)
        } catch (e: FileNotFoundException) {
            result.error("E_NOT_FOUND", e.message, null)
        } catch (e: Exception) {
            result.error("E_IO", e.message, null)
        }
    }

    companion object {
        private const val REQUEST_CODE_OPEN_TREE = 4401
        private const val REQUEST_CODE_AUDIO_PERMISSION = 4402
    }
}
