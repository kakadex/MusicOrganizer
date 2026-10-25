package com.dsh.musicorganizer.musicorganizer

import android.content.ContentResolver
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract

/**
 * SAF 目录树操作（DocumentsContract 直连，不引 AndroidX DocumentFile）。
 *
 * T03 只实现 listRoots / stat / listChildren 与 pickTree 的授权信息解析；
 * copy/write/readHead/readTail/create/delete/rename/move 留 T08。
 */
class SafPlugin(private val resolver: ContentResolver) {

    /** 一棵树的授权信息（treeUri + rootDocId）。 */
    fun treeInfo(treeUri: Uri): Map<String, String> {
        val rootDocId = DocumentsContract.getTreeDocumentId(treeUri) ?: ""
        return mapOf("treeUri" to treeUri.toString(), "rootDocId" to rootDocId)
    }

    /** 已持久授权的目录树列表。 */
    fun listRoots(): List<Map<String, String>> =
        resolver.persistedUriPermissions.map { perm -> treeInfo(perm.uri) }

    /** 单个文档信息；不存在返回 null。 */
    fun stat(treeUri: String, docId: String?): Map<String, Any>? {
        if (docId.isNullOrEmpty()) return null
        val uri = DocumentsContract.buildDocumentUriUsingTree(Uri.parse(treeUri), docId)
        return queryOne(uri, null)
    }

    /** 目录子项（按名排序 + docId 去重）。 */
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
