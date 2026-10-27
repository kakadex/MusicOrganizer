package com.dsh.musicorganizer.musicorganizer

import android.content.ContentResolver
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.content.ContentUris
import android.provider.DocumentsContract
import android.provider.MediaStore
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel

/**
 * SAF 目录树操作（DocumentsContract 直连，不引 AndroidX DocumentFile）。
 *
 * 列表 / 查询走 PROJECTION 五列；读写走 openInputStream / openOutputStream("wt")；
 * tail 用 openFileDescriptor + FileChannel.position（避免 InputStream.skip 逐字节退化）。
 */
class SafPlugin(private val resolver: ContentResolver) {

    fun treeInfo(treeUri: Uri): Map<String, String> {
        val rootDocId = DocumentsContract.getTreeDocumentId(treeUri) ?: ""
        return mapOf("treeUri" to treeUri.toString(), "rootDocId" to rootDocId)
    }

    /**
     * 已授权的目录树列表。
     *
     * 只认真正的目录树：系统这份授权表里还会混进单个文件的授权（例如用户在
     * 文件管理器里「用本应用打开」某个音频时顺手拿的持久授权）。对非目录树
     * 的 URI 调 getTreeDocumentId 会直接抛异常，让整次查询失败，Dart 侧就会
     * 误判成「授权失效」而提示重新选目录。所以这里先筛后解析，且逐条容错。
     */
    fun listRoots(): List<Map<String, String>> =
        resolver.persistedUriPermissions
            .map { perm -> perm.uri }
            .filter { DocumentsContract.isTreeUri(it) }
            .mapNotNull { uri ->
                runCatching { treeInfo(uri) }.getOrNull()?.takeIf {
                    it["rootDocId"].orEmpty().isNotEmpty()
                }
            }

    /**
     * 单个目录树的授权状态。
     *
     * 「系统没给授权」「授权在但盘没插」「授权表暂时读不出来」这三件事的
     * 应对完全不同，不能一律当成授权失效：只有 REVOKED 才该让用户重选，
     * 其余一律保留记录、等下次再试——把记录清掉，用户就永久丢了曲库目录。
     *
     * - VALID：授权在、根目录读得到 → 正常恢复
     * - REVOKED：系统授权表里没有这棵树 → 只能重新授权
     * - UNAVAILABLE：授权在但读不到（外置存储没插 / 目录被删）→ 保留并重试
     * - NOT_READY：授权表暂时读不出来（启动极早期）→ 延迟重试，不动状态
     */
    fun authState(treeUri: String): String {
        if (resolver.persistedUriPermissions.isEmpty()) return "NOT_READY"
        val uri = runCatching { Uri.parse(treeUri) }.getOrNull() ?: return "REVOKED"
        val granted = resolver.persistedUriPermissions.any { perm -> perm.uri == uri }
        if (!granted) return "REVOKED"
        val docId = runCatching { DocumentsContract.getTreeDocumentId(uri) }.getOrNull()
        if (docId.isNullOrEmpty()) return "REVOKED"
        val root = runCatching { stat(treeUri, docId) }.getOrNull()
        return if (root == null) "UNAVAILABLE" else "VALID"
    }

    fun stat(treeUri: String, docId: String?): Map<String, Any>? {
        if (docId.isNullOrEmpty()) return null
        val uri = documentUri(treeUri, docId)
        return queryOne(uri, null)
    }

    fun listChildren(treeUri: String, parentDocId: String?): List<Map<String, Any>> {
        if (parentDocId.isNullOrEmpty()) return emptyList()
        val uri =
            DocumentsContract.buildChildDocumentsUriUsingTree(Uri.parse(treeUri), parentDocId)
        val out = mutableListOf<Map<String, Any>>()
        val seen = mutableSetOf<String>()
        resolver.query(uri, PROJECTION, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val docId = cursor.getString(COL_ID) ?: continue
                if (!seen.add(docId)) continue
                out.add(fromCursor(cursor, parentDocId))
            }
        }
        out.sortBy { (it["name"] as String).lowercase() }
        return out
    }

    // ------------------------------------------------------------------
    // 流读写
    // ------------------------------------------------------------------

    /** 把文档复制到本地缓存；maxBytes<=0 表示整文件。返回实际字节数。 */
    fun copyDocToCache(treeUri: String, docId: String, cachePath: String, maxBytes: Int): Long {
        val uri = documentUri(treeUri, docId)
        val input = resolver.openInputStream(uri) ?: throw IOException("无法打开文档")
        return input.use { ins ->
            FileOutputStream(cachePath).use { out ->
                val buf = ByteArray(65536)
                var total = 0L
                while (true) {
                    val want = if (maxBytes <= 0) buf.size else minOf(buf.size, maxBytes - total.toInt())
                    if (want <= 0) break
                    val n = ins.read(buf, 0, want)
                    if (n <= 0) break
                    out.write(buf, 0, n)
                    total += n
                }
                out.flush()
                total
            }
        }
    }

    /** 用本地缓存覆盖写回文档（"wt" 截断写）。 */
    fun writeCacheToDoc(treeUri: String, docId: String, cachePath: String): Boolean {
        val uri = documentUri(treeUri, docId)
        val output = resolver.openOutputStream(uri, "wt") ?: return false
        return try {
            FileInputStream(cachePath).use { ins ->
                output.use { outs ->
                    val buf = ByteArray(65536)
                    var n = ins.read(buf)
                    while (n > 0) {
                        outs.write(buf, 0, n)
                        n = ins.read(buf)
                    }
                    outs.flush()
                }
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    /** 读文件头 maxBytes 字节。 */
    fun readHead(treeUri: String, docId: String, maxBytes: Int): ByteArray? {
        val uri = documentUri(treeUri, docId)
        val input = resolver.openInputStream(uri) ?: return null
        return input.use { ins ->
            val out = ByteArrayOutputStream(minOf(maxBytes, 64 * 1024))
            val buf = ByteArray(16384)
            var total = 0
            while (total < maxBytes) {
                val want = minOf(buf.size, maxBytes - total)
                val n = ins.read(buf, 0, want)
                if (n <= 0) break
                out.write(buf, 0, n)
                total += n
            }
            out.toByteArray()
        }
    }

    /** 读文件尾 maxBytes 字节（FileChannel.position 定位，不逐字节 skip）。 */
    fun readTail(treeUri: String, docId: String, maxBytes: Int): ByteArray? {
        if (maxBytes <= 0) return null
        val uri = documentUri(treeUri, docId)
        val pfd = resolver.openFileDescriptor(uri, "r") ?: return null
        try {
            val size = pfd.statSize
            if (size <= 0) return null
            val start = maxOf(0L, size - maxBytes)
            val want = minOf(maxBytes.toLong(), size - start).toInt()
            val fis = FileInputStream(pfd.fileDescriptor)
            try {
                val channel: FileChannel = fis.channel
                channel.position(start)
                val out = ByteArray(want)
                val buffer = ByteBuffer.wrap(out)
                while (buffer.hasRemaining()) {
                    if (channel.read(buffer) <= 0) break
                }
                val got = buffer.position()
                return if (got == out.size) out else out.copyOf(got)
            } finally {
                fis.close()
            }
        } finally {
            pfd.close()
        }
    }

    // ------------------------------------------------------------------
    // 创建 / 删除 / 重命名 / 移动
    // ------------------------------------------------------------------

    fun createDocument(
        treeUri: String, parentDocId: String, name: String, mime: String
    ): Map<String, Any> {
        val parentUri = documentUri(treeUri, parentDocId)
        val created = DocumentsContract.createDocument(resolver, parentUri, mime, name)
            ?: throw IOException("创建失败：$name")
        val docId = DocumentsContract.getDocumentId(created) ?: ""
        return mapOf(
            "docId" to docId,
            "parentId" to parentDocId,
            "name" to lastSegment(docId),
            "mime" to mime,
            "size" to 0L,
            "mtime" to 0L,
            "isDir" to false,
        )
    }

    fun createDir(treeUri: String, parentDocId: String, name: String): Map<String, Any> {
        val parentUri = documentUri(treeUri, parentDocId)
        val created = DocumentsContract.createDocument(
            resolver, parentUri, DocumentsContract.Document.MIME_TYPE_DIR, name
        ) ?: throw IOException("创建目录失败：$name")
        val docId = DocumentsContract.getDocumentId(created) ?: ""
        return mapOf(
            "docId" to docId,
            "parentId" to parentDocId,
            "name" to lastSegment(docId),
            "mime" to DocumentsContract.Document.MIME_TYPE_DIR,
            "size" to 0L,
            "mtime" to 0L,
            "isDir" to true,
        )
    }

    fun deleteDocument(treeUri: String, docId: String): Boolean {
        val uri = documentUri(treeUri, docId)
        return try {
            DocumentsContract.deleteDocument(resolver, uri)
        } catch (_: Exception) {
            false
        }
    }

    fun renameDocument(treeUri: String, docId: String, newName: String): Map<String, Any>? {
        val uri = documentUri(treeUri, docId)
        val renamed = DocumentsContract.renameDocument(resolver, uri, newName) ?: return null
        val newId = DocumentsContract.getDocumentId(renamed) ?: ""
        return mapOf("docId" to newId, "name" to newName)
    }

    /** 同一树内移动：优先 moveDocument，失败回退「复制 + 校验 + 删源」。 */
    fun moveDocument(
        treeUri: String, docId: String, sourceParentDocId: String?, targetParentDocId: String
    ): Boolean {
        val tree = Uri.parse(treeUri)
        val srcUri = documentUri(treeUri, docId)
        val srcParent = documentUri(
            treeUri,
            sourceParentDocId ?: (DocumentsContract.getTreeDocumentId(tree) ?: "")
        )
        val targetParent = documentUri(treeUri, targetParentDocId)
        val moved = try {
            DocumentsContract.moveDocument(resolver, srcUri, srcParent, targetParent)
        } catch (_: Exception) {
            null
        }
        return if (moved != null) true else moveFallback(tree, docId, targetParentDocId)
    }

    private fun moveFallback(tree: Uri, docId: String, targetParentDocId: String): Boolean {
        return try {
            val src = stat(tree.toString(), docId) ?: return false
            val name = src["name"] as? String ?: return false
            val mime = src["mime"] as? String ?: ""
            val size = src["size"] as? Long ?: 0L
            val tmp = File.createTempFile("mo_move_", ".bin")
            try {
                val copied = copyDocToCache(tree.toString(), docId, tmp.absolutePath, 0)
                if (size > 0 && copied != size) return false
                val created = createDocument(
                    tree.toString(), targetParentDocId, name,
                    if (mime.isEmpty()) "application/octet-stream" else mime
                )
                val createdId = created["docId"] as? String ?: return false
                if (!writeCacheToDoc(tree.toString(), createdId, tmp.absolutePath)) {
                    deleteDocument(tree.toString(), createdId)
                    return false
                }
                val after = stat(tree.toString(), createdId)
                if (size > 0 && (after?.get("size") as? Long ?: 0L) != size) {
                    deleteDocument(tree.toString(), createdId)
                    return false
                }
                if (!deleteDocument(tree.toString(), docId)) {
                    deleteDocument(tree.toString(), createdId)
                    return false
                }
                true
            } finally {
                tmp.delete()
            }
        } catch (_: Exception) {
            false
        }
    }

    // ------------------------------------------------------------------
    // 内部工具
    // ------------------------------------------------------------------

    private fun documentUri(treeUri: String, docId: String): Uri =
        DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUri), docId)

    private fun queryOne(uri: Uri, parentId: String?): Map<String, Any>? {
        resolver.query(uri, PROJECTION, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                return fromCursor(cursor, parentId)
            }
        }
        return null
    }

    private fun fromCursor(cursor: Cursor, parentId: String?): Map<String, Any> {
        val mime = cursor.getString(COL_MIME) ?: ""
        val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR
        val size = if (cursor.isNull(COL_SIZE)) 0L else cursor.getLong(COL_SIZE)
        val mtime = if (cursor.isNull(COL_MTIME)) 0L else cursor.getLong(COL_MTIME)
        return mapOf(
            "docId" to (cursor.getString(COL_ID) ?: ""),
            "parentId" to (parentId ?: ""),
            "name" to (cursor.getString(COL_NAME) ?: ""),
            "mime" to mime,
            "size" to size,
            "mtime" to mtime,
            "isDir" to isDir,
        )
    }

    // ------------------------------------------------------------------
    // 系统媒体库（MediaStore）
    // ------------------------------------------------------------------

    /**
     * 扫系统媒体库里的音频条目。
     *
     * 需要用户授权读取音频（READ_MEDIA_AUDIO / READ_EXTERNAL_STORAGE），
     * 由上层在用户明确点「从系统媒体库导入」时才申请。
     */
    fun mediaStoreAudio(minDurationMs: Int): List<Map<String, Any?>> {
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.SIZE,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.RELATIVE_PATH,
        )
        val out = mutableListOf<Map<String, Any?>>()
        resolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection, null, null, null
        )?.use { cursor ->
            val colId = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val colName = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val colArtist = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val colAlbum = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val colTitle = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val colDur = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val colSize = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)
            val colMime = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.MIME_TYPE)
            val colPath = cursor.getColumnIndex(MediaStore.Audio.Media.RELATIVE_PATH)
            while (cursor.moveToNext()) {
                val dur = cursor.getLong(colDur)
                if (dur < minDurationMs) continue
                val id = cursor.getLong(colId)
                val rawArtist = cursor.getString(colArtist) ?: ""
                val rawAlbum = cursor.getString(colAlbum) ?: ""
                out.add(
                    mapOf(
                        "id" to id,
                        "uri" to ContentUris.withAppendedId(
                            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id
                        ).toString(),
                        "name" to (cursor.getString(colName) ?: ""),
                        // ARTIST 列经常是字面量 <unknown>，当空
                        "artist" to rawArtist.trim().removePrefix("<unknown>").trim(),
                        "album" to rawAlbum.trim().removePrefix("<unknown>").trim(),
                        "title" to (cursor.getString(colTitle) ?: "").trim(),
                        "durationMs" to dur,
                        "size" to cursor.getLong(colSize),
                        "mime" to (cursor.getString(colMime) ?: ""),
                        // 相册/音乐目录相对路径（如 Music/周杰伦/），用来判断「是不是已在曲库里」
                        "relativePath" to
                            if (colPath >= 0) (cursor.getString(colPath) ?: "") else "",
                    )
                )
            }
        }
        out.sortBy { (it["name"] as String).lowercase() }
        return out
    }

    /** 把媒体库里的一个音频复制到本地缓存（导入用）。返回字节数。 */
    fun copyMediaToCache(contentUri: String, cachePath: String): Long {
        val input = resolver.openInputStream(Uri.parse(contentUri))
            ?: throw IOException("无法打开媒体库条目")
        input.use { ins ->
            FileOutputStream(cachePath).use { out ->
                val buf = ByteArray(65536)
                var total = 0L
                while (true) {
                    val n = ins.read(buf)
                    if (n <= 0) break
                    out.write(buf, 0, n)
                    total += n
                }
                out.flush()
                return total
            }
        }
    }

    /**
     * 外部调起的文件信息（显示名 + 大小 + 可读写的字节长度）。
     *
     * 用于「在文件管理器里用本应用打开音频」：先拿名字和大小去曲库里找，
     * 找得到就直接在编辑器里打开，找不到再引导用户授权所在目录。
     */
    fun uriInfo(uriString: String): Map<String, Any>? {
        val uri = Uri.parse(uriString)
        val out = mutableMapOf<String, Any>()
        resolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIdx = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                val sizeIdx = cursor.getColumnIndex(android.provider.OpenableColumns.SIZE)
                if (nameIdx >= 0) out["name"] = cursor.getString(nameIdx) ?: ""
                if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) out["size"] = cursor.getLong(sizeIdx)
            }
        }
        if (out.isEmpty()) {
            out["name"] = uri.lastPathSegment ?: ""
            out["size"] = 0L
        }
        return out
    }

    private fun lastSegment(docId: String): String {
        val idx = docId.lastIndexOf('/')
        return if (idx >= 0) docId.substring(idx + 1) else docId
    }

    companion object {
        private val PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        private const val COL_ID = 0
        private const val COL_NAME = 1
        private const val COL_MIME = 2
        private const val COL_SIZE = 3
        private const val COL_MTIME = 4
    }
}
