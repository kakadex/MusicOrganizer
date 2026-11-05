package com.dsh.musicorganizer.musicorganizer

import android.app.Activity
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {

    private var pendingPickResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingNotificationResult: MethodChannel.Result? = null
    private lateinit var safPlugin: SafPlugin
    private var hostChannel: MethodChannel? = null

    /**
     * SAF 调用的后台线程池。
     *
     * 每一次 `resolver.query` / `openInputStream` 都是一次跨进程调用：要等
     * DocumentsProvider 那边（文件管理器、网盘、U 盘驱动）回话，正常几毫秒，
     * 卡的时候几十上百毫秒。这些调用原来全跑在平台主线程上，所以一次全量扫描
     * 要发几千次，界面就一直在等同一个 Looper —— 表现就是列表卡、点返回没反应。
     *
     * 用池而不是单线程：Dart 侧补读标签是 8 路并发（`organize_page._readTagArtists`），
     * 单线程会把并发压成串行，查重前的标签补读反而变慢。4 条线程够覆盖这个并发，
     * 又不会让 provider 同时承受太多请求。
     *
     * 核心线程可超时回收：Activity 重建、引擎被缓存时不一定会走到
     * [cleanUpFlutterEngine]，空闲 30 秒后这些线程自己退出，不留悬挂线程。
     */
    private val safIo = ThreadPoolExecutor(
        SAF_THREADS,
        SAF_THREADS,
        30L,
        TimeUnit.SECONDS,
        LinkedBlockingQueue(),
        { r -> Thread(r, "saf-io").apply { isDaemon = true } },
    ).apply { allowCoreThreadTimeOut(true) }

    /**
     * 交互池：「要快」的小调用走这里（0.2.68）。
     *
     * 原来只有一个 4 线程池 + FIFO 无界队列：用户快速滚动时那几个「读 256KB
     * 拿封面」的小请求，会排在一次批量读标签的「读 2MB」后面。单个 2MB 跨进程
     * 读在慢 provider 上是 50~200ms，于是封面看起来半天才出来、滚动时一片灰格子
     * 突然跳出来。拆成两个池后，批量任务再也堵不住滚动。
     *
     * 2 条线程够覆盖「一屏几行同时要封面」，又给 provider 留余量。
     */
    private val safIoUi = ThreadPoolExecutor(
        SAF_UI_THREADS,
        SAF_UI_THREADS,
        30L,
        TimeUnit.SECONDS,
        LinkedBlockingQueue(),
        { r -> Thread(r, "saf-io-ui").apply { isDaemon = true } },
    ).apply { allowCoreThreadTimeOut(true) }

    /**
     * 已取消的批次令牌（0.2.68）。
     *
     * 用户返回 / 取消批量任务后，池子里排队的调用原来仍会跑完再丢结果，白白占着
     * provider、挡住别人的请求。Dart 侧把令牌置位后，排队任务在执行前先看一眼，
     * 已取消就直接返回错误、不碰磁盘。
     */
    private val cancelledTokens: MutableSet<String> =
        java.util.Collections.synchronizedSet(mutableSetOf())

    /// 回主线程用：MethodChannel 的结果只能在平台主线程回调。
    private val mainHandler = Handler(Looper.getMainLooper())

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
                    val title = call.argument<String>("title") ?: "正在处理"
                    val text = call.argument<String>("text") ?: ""
                    val done = call.argument<Int>("done") ?: 0
                    val total = call.argument<Int>("total") ?: 0
                    val seq = call.argument<Int>("seq") ?: 0
                    // 服务已经进过前台：只刷通知，绝不再 startForegroundService。
                    // 重复启动会不断刷新「5 秒内必须 startForeground」的计时，
                    // 超时系统直接杀进程（ForegroundServiceDidNotStartInTime）。
                    val live = TaskForegroundService.instance
                    if (TaskForegroundService.isForeground() && live != null) {
                        runCatching { live.update(title, text, done, total) }
                    } else {
                        val taskIntent = Intent(this, TaskForegroundService::class.java).apply {
                            action = TaskForegroundService.ACTION_START
                            putExtra(TaskForegroundService.EXTRA_SEQ, seq)
                            putExtra(TaskForegroundService.EXTRA_TITLE, title)
                            putExtra(TaskForegroundService.EXTRA_TEXT, text)
                            putExtra(TaskForegroundService.EXTRA_DONE, done)
                            putExtra(TaskForegroundService.EXTRA_TOTAL, total)
                        }
                        android.util.Log.d(
                            TaskForegroundService.TRACE_TAG,
                            "startForegroundService seq=$seq ts=${android.os.SystemClock.uptimeMillis()}"
                        )
                        // API 31+ 从后台启前台服务会被系统拒绝。先看界面是否可见：
                        // 不可见就直接走普通服务（任务多半是秒级收尾，不需要前台保护），
                        // 不再依赖「抛异常再补救」这条路。
                        if (android.os.Build.VERSION.SDK_INT >= 31 && !resumed) {
                            runCatching { startService(taskIntent) }
                        } else {
                            runCatching { startForegroundServiceCompat(taskIntent) }
                                .onFailure { runCatching { startService(taskIntent) } }
                        }
                    }
                    result.success(null)
                }
                "stopTask" -> {
                    val seq = call.argument<Int>("seq") ?: 0
                    val stopIntent = Intent(this, TaskForegroundService::class.java).apply {
                        action = TaskForegroundService.ACTION_STOP
                        putExtra(TaskForegroundService.EXTRA_SEQ, seq)
                    }
                    android.util.Log.d(
                        TaskForegroundService.TRACE_TAG,
                        "stopTask seq=$seq foreground=${TaskForegroundService.isForeground()} " +
                            "ts=${android.os.SystemClock.uptimeMillis()}"
                    )
                    if (TaskForegroundService.isForeground()) {
                        // 契约已经满足，直接停是安全的
                        runCatching { stopService(stopIntent) }
                    } else {
                        // 服务还没进前台：此刻 stopService 会被系统当成
                        // 「起了服务却没调 startForeground」直接杀进程。
                        // 改成投递一条停止命令：它排在启动命令之后，由同一个服务
                        // 按顺序消费，进完前台自己收尾。
                        val delivered = runCatching { startService(stopIntent) }.isSuccess
                        // 后台启动限制下 startService 会被拒：这时服务多半已经起来了，退回直接停
                        if (!delivered) runCatching { stopService(stopIntent) }
                    }
                    result.success(null)
                }
                "takeInitialIntent" -> result.success(initialFileUri)
                // 应用内更新：返回下载目录的绝对路径（Android 15 起不能写死外部路径）
                "updateDir" -> {
                    result.success(File(cacheDir, "updates").absolutePath)
                }
                // 拉起系统安装器。路径必须是上面 updateDir 返回的目录里的文件，
                // 通过 FileProvider 授权读权限——Android 8+ 不允许直接给 file://
                "installApk" -> {
                    val path = call.argument<String>("path") ?: ""
                    result.success(installApkFromUpdateDir(path))
                }
                "exportText" -> {
                    // 让用户自己挑保存位置（下载 / 文档 / 网盘），返回 true=已保存
                    pendingExportText = call.argument<String>("text") ?: ""
                    pendingExportResult = result
                    val name = call.argument<String>("name") ?: "musicorganizer-log.txt"
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }
                    runCatching { startActivityForResult(intent, REQUEST_CODE_EXPORT_TEXT) }
                        .onFailure {
                            pendingExportResult = null
                            result.success(false)
                        }
                }
                "uriInfo" -> safCall("uriInfo", result) {
                    safPlugin.uriInfo(call.argument<String>("uri") ?: "")
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dsh.musicorganizer/saf"
        ).setMethodCallHandler { call, result ->
            // 0.2.68：Dart 侧可给每次调用标「交互优先」与「所属批次令牌」。
            // priority=true 走 safIoUi（2 线程），否则走 safIo（4 线程）。
            // token 被取消后，排队中的任务执行前直接返回 E_CANCELLED，不碰磁盘。
            val prio = call.argument<Boolean>("priority") == true
            val tok = call.argument<String>("token")
            when (call.method) {
                "pickTree" -> {
                    pendingPickResult = result
                    startActivityForResult(
                        Intent(Intent.ACTION_OPEN_DOCUMENT_TREE),
                        REQUEST_CODE_OPEN_TREE
                    )
                }
                "cancelBatch" -> {
                    val t = call.argument<String>("token") ?: ""
                    if (t.isNotEmpty()) {
                        cancelledTokens.add(t)
                        // 取消完顺手清掉，避免长期运行时集合只增不减
                        if (cancelledTokens.size > 32) cancelledTokens.clear()
                    }
                    result.success(null)
                }
                "listRoots" -> safCall("listRoots", result, prio, tok) { safPlugin.listRoots() }
                "authState" -> safCall("authState", result, prio, tok) {
                    safPlugin.authState(call.argument<String>("treeUri") ?: "")
                }
                "stat" -> safCall("stat", result, prio, tok) {
                    safPlugin.stat(call.argument<String>("treeUri") ?: "", call.argument<String>("docId"))
                }
                "listChildren" -> safCall("listChildren", result, prio, tok) {
                    safPlugin.listChildren(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("parentDocId")
                    )
                }
                "copyDocToCache" -> safCall("copyDocToCache", result, prio, tok) {
                    safPlugin.copyDocToCache(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: "",
                        call.argument<String>("cachePath") ?: "",
                        call.argument<Int>("maxBytes") ?: 0
                    )
                }
                "writeCacheToDoc" -> safCall("writeCacheToDoc", result, prio, tok) {
                    safPlugin.writeCacheToDoc(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: "",
                        call.argument<String>("cachePath") ?: ""
                    )
                }
                "readHead" -> safCall("readHead", result, prio, tok) {
                    safPlugin.readHead(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: "",
                        call.argument<Int>("maxBytes") ?: 0
                    )
                }
                "readTail" -> safCall("readTail", result, prio, tok) {
                    safPlugin.readTail(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: "",
                        call.argument<Int>("maxBytes") ?: 0
                    )
                }
                "readRange" -> safCall("readRange", result, prio, tok) {
                    safPlugin.readRange(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: "",
                        (call.argument<Number>("offset") ?: 0).toLong(),
                        call.argument<Int>("maxBytes") ?: 0
                    )
                }
                "createDocument" -> safCall("createDocument", result, prio, tok) {
                    safPlugin.createDocument(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("parentDocId") ?: "",
                        call.argument<String>("name") ?: "",
                        call.argument<String>("mime") ?: "application/octet-stream"
                    )
                }
                "createDir" -> safCall("createDir", result, prio, tok) {
                    safPlugin.createDir(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("parentDocId") ?: "",
                        call.argument<String>("name") ?: ""
                    )
                }
                "deleteDocument" -> safCall("deleteDocument", result, prio, tok) {
                    safPlugin.deleteDocument(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: ""
                    )
                }
                "renameDocument" -> safCall("renameDocument", result, prio, tok) {
                    safPlugin.renameDocument(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("docId") ?: "",
                        call.argument<String>("newName") ?: ""
                    )
                }
                "moveDocument" -> safCall("moveDocument", result, prio, tok) {
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
                "mediaStoreAudio" -> safCall("mediaStoreAudio", result, prio, tok) {
                    safPlugin.mediaStoreAudio(call.argument<Int>("minDurationMs") ?: 0)
                }
                "copyMediaToCache" -> safCall("copyMediaToCache", result, prio, tok) {
                    safPlugin.copyMediaToCache(
                        call.argument<String>("uri") ?: "",
                        call.argument<String>("cachePath") ?: ""
                    )
                }
                "requestAudioPermission" -> requestAudioPermission(result)
                // 安卓 13+ 通知权限必须运行时申请：只在清单里声明，通知栏永远不显示
                // 任务进度通知，用户切后台也看不到「匹配到第几首」。
                "requestNotificationPermission" -> requestNotificationPermission(result)
                // 给 Dart 侧一个可查的前台服务状态，任务结束后不必靠猜
                "serviceState" -> result.success(TaskForegroundService.state())
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
    private var pendingExportText: String? = null
    private var pendingExportResult: MethodChannel.Result? = null

    /// 界面此刻是否可见。API 31+ 禁止从后台启前台服务，起服务前要先看这个，
    /// 而不是等抛了 ForegroundServiceStartNotAllowedException 再补救。
    @Volatile
    private var resumed = false

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        initialFileUri = fileUriFrom(intent)
    }

    override fun onResume() {
        super.onResume()
        resumed = true
    }

    override fun onPause() {
        resumed = false
        super.onPause()
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
        if (requestCode == REQUEST_CODE_EXPORT_TEXT) {
            val res = pendingExportResult
            pendingExportResult = null
            val text = pendingExportText ?: ""
            pendingExportText = null
            val uri: Uri? = if (resultCode == Activity.RESULT_OK) data?.data else null
            if (uri == null) {
                res?.success(false)
                return
            }
            val ok = runCatching {
                contentResolver.openOutputStream(uri)?.use { out ->
                    out.write(text.toByteArray(Charsets.UTF_8))
                    out.flush()
                } != null
            }.getOrDefault(false)
            res?.success(ok)
            return
        }
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
        } catch (e: Exception) {
            // 拿不到持久授权：本次会话里也许还能读，但重启后必然「丢目录」。
            // 这里必须当场报错让用户换一个目录重选，不能静默成功把问题留到下次启动。
            result?.error(
                "E_NO_PERMISSION",
                "系统未授予该目录的持久访问权限（${e.message}），请换一个目录重新选择",
                null
            )
            return
        }
        result?.success(safPlugin.treeInfo(uri))
    }

    /**
     * 申请读取音频的权限（只在用户明确要导入系统媒体库时才申请）。
     *
     * 安卓 13+ 要 READ_MEDIA_AUDIO，更早的版本要 READ_EXTERNAL_STORAGE。
     */
    /// 安卓 13+ 通知权限运行时申请。13 以下清单声明即生效，直接返回 true。
    /// 用户拒绝过也不纠缠：返回 false，Dart 侧任务照跑，只是没通知。
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (android.os.Build.VERSION.SDK_INT < 33) {
            result.success(true)
            return
        }
        val permission = "android.permission.POST_NOTIFICATIONS"
        if (checkSelfPermission(permission) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        pendingNotificationResult = result
        requestPermissions(arrayOf(permission), REQUEST_CODE_NOTIFICATION_PERMISSION)
    }

    private fun requestAudioPermission(result: MethodChannel.Result) {        val permission = if (android.os.Build.VERSION.SDK_INT >= 33) {
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
        if (requestCode == REQUEST_CODE_NOTIFICATION_PERMISSION) {
            val result = pendingNotificationResult
            pendingNotificationResult = null
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
            result?.success(granted)
            return
        }
        if (requestCode != REQUEST_CODE_AUDIO_PERMISSION) return
        val result = pendingPermissionResult
        pendingPermissionResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
        result?.success(granted)
    }

    /**
     * 把一次 SAF 调用挪到后台线程执行，结果回主线程再回给 Dart。
     *
     * 线程安全：SafPlugin 的各方法只持有各自的局部变量（`seen`、`out` 都在方法里），
     * 不共享可变字段，可以并发跑。同一个文件上的「读-改-写」靠 Dart 侧逐次 await
     * 保证先后——它拿到上一次的结果才会发下一次，所以池子不会把同一串操作打乱。
     *
     * 异常映射保持原样：SecurityException / FileNotFoundException / 其他都映射成
     * Dart 侧认识的错误码，后台线程抛异常不会冒到主线程把进程带崩。
     *
     * [method] 只用于慢调用日志（`adb logcat -s SafIo`），排查「哪一步慢」时有据可查。
     */
    private fun safCall(
        method: String,
        result: MethodChannel.Result,
        priority: Boolean = false,
        token: String? = null,
        block: () -> Any?,
    ) {
        val started = SystemClock.uptimeMillis()
        val task = Runnable {
            // 排队期间用户已经取消了这一批：直接返回，不碰磁盘/provider。
            if (token != null && token.isNotEmpty() && cancelledTokens.contains(token)) {
                mainHandler.post {
                    runCatching { result.error("E_CANCELLED", "已取消", null) }
                }
                return@Runnable
            }
            var value: Any? = null
            var code: String? = null
            var message: String? = null
            try {
                value = block()
            } catch (e: SecurityException) {
                code = "E_NO_PERMISSION"
                message = e.message
            } catch (e: FileNotFoundException) {
                code = "E_NOT_FOUND"
                message = e.message
            } catch (e: Exception) {
                code = "E_IO"
                message = e.message
            }
            val cost = SystemClock.uptimeMillis() - started
            if (cost >= SLOW_CALL_MS) {
                Log.w(TAG, "saf $method 耗时 ${cost}ms（后台线程，含排队）")
            }
            val valueFinal = value
            val codeFinal = code
            val messageFinal = message
            mainHandler.post {
                // 引擎已经销毁时 result 的发不出去，抛了也不该崩
                runCatching {
                    if (codeFinal == null) result.success(valueFinal)
                    else result.error(codeFinal, messageFinal, null)
                }
            }
        }
        // 交互池 vs 批量池：小的、滚屏要用的走 UI 池，别被批量任务堵住。
        val pool = if (priority) safIoUi else safIo
        try {
            pool.execute(task)
        } catch (_: RejectedExecutionException) {
            // 引擎正在销毁、池子已关：这次调用没人等了，直接丢弃
        }
    }

    /**
     * 拉起系统安装器安装下载好的 APK（0.2.70）。
     *
     * 三道必要措施，缺一不可：
     * 1. **只允许安装 [updateDir] 里的文件**——Dart 侧传来的是绝对路径，
     *    若不加校验，等于开放了「安装任意路径 APK」的能力。
     * 2. **FileProvider 授权**——Android 8+ 禁止 `file://` 直传，
     *    必须用 content:// + FLAG_GRANT_READ_URI_PERMISSION，
     *    且路径必须落在 file_paths.xml 声明的范围内，否则安装器打不开。
     * 3. **FLAG_ACTIVITY_NEW_TASK**——从非 Activity 上下文调起需要它。
     *
     * 返回 true 表示已拉起安装界面；false 表示文件不存在或系统拒绝。
     */
    private fun installApkFromUpdateDir(path: String): Boolean {
        if (path.isEmpty()) return false
        val allowedDir = File(cacheDir, "updates").canonicalFile
        val apk = runCatching { File(path).canonicalFile }.getOrNull() ?: return false
        if (!apk.exists() || !apk.isFile) return false
        // 必须真的在下载目录里（防止 ../ 穿越到别处）
        if (!apk.path.startsWith(allowedDir.path + File.separator)) return false
        return try {
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.updates",
                apk,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            // 只记异常类名，不记 message：FileProvider 的异常信息里可能带
            // APK 的绝对路径，而这行日志不走 Dart 侧的 Log.sanitize，
            // 直接落进 logcat 就绕过了脱敏（性能排查报告附录 B 的警告）。
            Log.w(TAG, "拉起安装器失败：${e.javaClass.simpleName}")
            false
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {        // 已经排队的任务让它跑完（结果发不出去由上面 runCatching 兜住），
        // 只关入口不再接收新调用。
        safIo.shutdown()
        safIoUi.shutdown()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object {
        private const val REQUEST_CODE_OPEN_TREE = 4401
        private const val REQUEST_CODE_EXPORT_TEXT = 4402
        private const val REQUEST_CODE_AUDIO_PERMISSION = 4402
        private const val REQUEST_CODE_NOTIFICATION_PERMISSION = 4403

        /// SAF 后台线程数（批量池；取值理由见 safIo 的注释）。
        private const val SAF_THREADS = 4

        /// SAF 交互池线程数（滚屏读封面这类「要快」的调用）。
        private const val SAF_UI_THREADS = 2

        /// 单次 SAF 调用超过这个耗时就记一条日志（真机上排查慢查询用）。
        private const val SLOW_CALL_MS = 200L

        /// 日志标签：`adb logcat -s SafIo` 只看 SAF 相关。
        private const val TAG = "SafIo"
    }
}
