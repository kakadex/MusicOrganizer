package com.dsh.musicorganizer.core;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.DocumentsContract;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

/**
 * SAF 存储访问层 —— 所有目录树操作的唯一入口。
 *
 * 不引入 DocumentFile / AndroidX，直接使用框架 DocumentsContract：
 *   * 列目录 / 读流 / 写流 / 建文件 / 建目录 / 删除 / 重命名 / 移动
 * 移动优先走 moveDocument，失败自动回退「复制 + 校验 + 删除」。
 */
public final class Storage {

    private static final String[] PROJECTION = {
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
    };
    private static final int COL_ID = 0;
    private static final int COL_NAME = 1;
    private static final int COL_MIME = 2;
    private static final int COL_SIZE = 3;
    private static final int COL_MTIME = 4;

    private final ContentResolver resolver;
    private final Uri treeUri;
    private final String rootDocId;

    /** 当前活动的实例（供 Cleaner 等静态工具便捷调用）。 */
    private static volatile Storage active;

    public Storage(ContentResolver resolver, Uri treeUri) throws IOException {
        this.resolver = resolver;
        this.treeUri = treeUri;
        String id = DocumentsContract.getTreeDocumentId(treeUri);
        if (id == null || id.isEmpty()) {
            throw new IOException("无法解析目录树 ID");
        }
        this.rootDocId = id;
        active = this;
    }

    /** 静态重命名：委托给当前活动实例。 */
    public static boolean renameStatic(VFile f, String newName) {
        Storage s = active;
        return s != null && s.rename(f, newName);
    }

    /** 静态删除：委托给当前活动实例。 */
    public static boolean deleteStatic(VFile f) {
        Storage s = active;
        return s != null && s.delete(f);
    }

    public String rootDocId() {
        return rootDocId;
    }

    public Uri documentUri(String docId) {
        return DocumentsContract.buildDocumentUriUsingTree(treeUri, docId);
    }

    public Uri documentUri(VFile f) {
        return documentUri(f.docId);
    }

    public VFile root() {
        return stat(rootDocId, null);
    }

    // ------------------------------------------------------------------
    // 查询
    // ------------------------------------------------------------------

    /** 读取单个文档信息；父 ID 未知时传 null。 */
    public VFile stat(String docId, String parentId) {
        Cursor c = null;
        try {
            c = resolver.query(documentUri(docId), PROJECTION, null, null, null);
            if (c != null && c.moveToFirst()) {
                return fromCursor(c, parentId);
            }
            return null;
        } catch (Exception e) {
            return null;
        } finally {
            closeQuietly(c);
        }
    }

    /**
     * 列出目录子项（按名称排序）。
     *
     * <p>按 {@code docId} 去重（v0.1.57）：部分系统（实测 MIUI / 某些网盘 provider）的
     * SAF 查询会把同一个文档返回多次。不去重的话，目录被遍历两遍、下面的文件全部重复，
     * 库页就会把同一首歌列成两条，曲目数也跟着翻倍。
     */
    public List<VFile> children(VFile dir) {
        List<VFile> out = new ArrayList<VFile>();
        java.util.Set<String> seenIds = new java.util.HashSet<String>();
        Uri uri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, dir.docId);
        Cursor c = null;
        try {
            c = resolver.query(uri, PROJECTION, null, null, null);
            if (c != null) {
                while (c.moveToNext()) {
                    VFile f = fromCursor(c, dir.docId);
                    if (f != null && seenIds.add(f.docId)) {
                        out.add(f);
                    }
                }
            }
        } catch (Exception ignored) {
        } finally {
            closeQuietly(c);
        }
        Collections.sort(out, new Comparator<VFile>() {
            @Override
            public int compare(VFile a, VFile b) {
                return a.name.toLowerCase(Locale.ROOT)
                        .compareTo(b.name.toLowerCase(Locale.ROOT));
            }
        });
        return out;
    }

    private VFile fromCursor(Cursor c, String parentId) {
        try {
            String id = c.getString(COL_ID);
            String name = c.getString(COL_NAME);
            String mime = c.getString(COL_MIME);
            long size = c.isNull(COL_SIZE) ? 0 : c.getLong(COL_SIZE);
            long mtime = c.isNull(COL_MTIME) ? 0 : c.getLong(COL_MTIME);
            boolean dir = DocumentsContract.Document.MIME_TYPE_DIR.equals(mime);
            if (id == null || name == null) {
                return null;
            }
            return new VFile(id, parentId, name, mime, size, mtime, dir);
        } catch (Exception e) {
            return null;
        }
    }

    /** 显示用路径（去掉 root 前缀）。 */
    public String displayPath(VFile f) {
        String p = f.pathAfterRoot();
        return p.isEmpty() ? "/" : "/" + p;
    }

    // ------------------------------------------------------------------
    // 流读写
    // ------------------------------------------------------------------

    public InputStream open(VFile f) throws IOException {
        InputStream in = resolver.openInputStream(documentUri(f));
        if (in == null) {
            throw new IOException("无法打开：" + f.name);
        }
        return in;
    }

    public OutputStream openWrite(VFile f) throws IOException {
        OutputStream out = resolver.openOutputStream(documentUri(f), "wt");
        if (out == null) {
            throw new IOException("无法写入：" + f.name);
        }
        return out;
    }

    /** 把 SAF 文件复制到本地缓存文件。 */
    public void copyToLocal(VFile f, File target) throws IOException {
        InputStream in = null;
        OutputStream out = null;
        try {
            in = open(f);
            out = new FileOutputStream(target);
            pump(in, out);
        } finally {
            closeQuietly(in);
            closeQuietly(out);
        }
    }

    /**
     * 只把文件开头 maxBytes 复制到本地（读标签用）。返回实际复制字节数。
     *
     * <p>为什么需要：ID3 / FLAC 的标签都在文件头部，老实现为了读标签把整个音频
     * 复制到临时目录，一首 FLAC 动辄 30MB —— 批量几百首就是几 GB 的额外读写，
     * 比网络还慢。只读头部能把这段开销降到原来的 1/10 以下。
     * 返回字节数等于 maxBytes 时说明可能没读全，调用方需判断标签是否已完整。
     */
    /**
     * 直接读文件头部若干字节（v0.1.58）：给「同名同内容」判定用。
     *
     * <p>与 {@link #copyHeadToLocal} 的区别是不落临时文件 —— 只读一次、马上比较，
     * 少一次磁盘往返。
     */
    public byte[] headBytes(VFile f, int maxBytes) {
        java.io.InputStream in = null;
        try {
            in = open(f);
            java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream(
                    Math.min(maxBytes, 64 * 1024));
            byte[] buf = new byte[16384];
            int total = 0;
            while (total < maxBytes) {
                int want = Math.min(buf.length, maxBytes - total);
                int n = in.read(buf, 0, want);
                if (n <= 0) {
                    break;
                }
                out.write(buf, 0, n);
                total += n;
            }
            return out.toByteArray();
        } catch (Throwable t) {
            return null;
        } finally {
            closeQuietly(in);
        }
    }

    public int copyHeadToLocal(VFile f, File target, int maxBytes) throws IOException {
        InputStream in = null;
        OutputStream out = null;
        int total = 0;
        try {
            in = open(f);
            out = new FileOutputStream(target);
            byte[] buf = new byte[65536];
            while (total < maxBytes) {
                int want = Math.min(buf.length, maxBytes - total);
                int n = in.read(buf, 0, want);
                if (n <= 0) {
                    break;
                }
                out.write(buf, 0, n);
                total += n;
            }
        } finally {
            closeQuietly(in);
            closeQuietly(out);
        }
        return total;
    }

    /** 把本地文件写回 SAF 文件（wt 截断模式）。 */
    public void writeFromLocal(VFile f, File source) throws IOException {
        InputStream in = null;
        OutputStream out = null;
        try {
            in = new FileInputStream(source);
            out = openWrite(f);
            pump(in, out);
        } finally {
            closeQuietly(in);
            closeQuietly(out);
        }
    }

    private static void pump(InputStream in, OutputStream out) throws IOException {
        byte[] buf = new byte[65536];
        int n;
        while ((n = in.read(buf)) > 0) {
            out.write(buf, 0, n);
        }
        out.flush();
    }

    // ------------------------------------------------------------------
    // 创建 / 删除 / 重命名 / 移动
    // ------------------------------------------------------------------

    public VFile createFile(VFile parent, String displayName, String mime) throws IOException {
        try {
            Uri created = DocumentsContract.createDocument(
                    resolver, documentUri(parent), mime, displayName);
            if (created == null) {
                throw new IOException("创建失败：" + displayName);
            }
            String id = DocumentsContract.getDocumentId(created);
            String name = lastSegment(id);
            return new VFile(id, parent.docId, name, mime, 0, 0, false);
        } catch (IOException e) {
            throw e;
        } catch (Exception e) {
            throw new IOException("创建失败：" + displayName + "（" + TextUtil.shortError(e) + "）");
        }
    }

    public VFile createDir(VFile parent, String displayName) throws IOException {
        try {
            Uri created = DocumentsContract.createDocument(
                    resolver, documentUri(parent),
                    DocumentsContract.Document.MIME_TYPE_DIR, displayName);
            if (created == null) {
                throw new IOException("创建目录失败：" + displayName);
            }
            String id = DocumentsContract.getDocumentId(created);
            return new VFile(id, parent.docId, lastSegment(id),
                    DocumentsContract.Document.MIME_TYPE_DIR, 0, 0, true);
        } catch (IOException e) {
            throw e;
        } catch (Exception e) {
            throw new IOException("创建目录失败：" + displayName + "（" + TextUtil.shortError(e) + "）");
        }
    }

    private static String lastSegment(String docId) {
        int idx = docId.lastIndexOf('/');
        return idx >= 0 ? docId.substring(idx + 1) : docId;
    }

    public boolean delete(VFile f) {
        try {
            return DocumentsContract.deleteDocument(resolver, documentUri(f));
        } catch (Exception e) {
            return false;
        }
    }

    public boolean rename(VFile f, String newName) {
        try {
            Uri renamed = DocumentsContract.renameDocument(
                    resolver, documentUri(f), newName);
            return renamed != null;
        } catch (Exception e) {
            return false;
        }
    }

    /** 在同一树内移动：优先 moveDocument，失败回退复制+删除。 */
    public boolean move(VFile f, VFile targetDir) {
        return moveWithReason(f, targetDir) == null;
    }

    /**
     * 同 {@link #move}，但把失败原因带出来（成功返回 null）。
     * 之前只有 boolean，出问题只会打印「移动失败：xxx」——查不出是源失效、同名冲突还是权限。
     */
    public String moveWithReason(VFile f, VFile targetDir) {
        if (f.parentId != null && f.parentId.equals(targetDir.docId)) {
            return null;
        }
        String moveError = null;
        try {
            Uri src = documentUri(f);
            Uri sourceParent = DocumentsContract.buildDocumentUriUsingTree(
                    treeUri, f.parentId == null ? rootDocId : f.parentId);
            Uri moved = DocumentsContract.moveDocument(
                    resolver, src, sourceParent, documentUri(targetDir));
            if (moved != null) {
                return null;
            }
            moveError = "系统未完成移动（moveDocument 返回空）";
        } catch (Exception e) {
            moveError = "moveDocument 异常：" + TextUtil.shortError(e);
        }
        // 回退：复制 → 字节数校验 → 删除
        File tmp = null;
        try {
            tmp = File.createTempFile("mo_move_", ".bin");
            copyToLocal(f, tmp);
            if (tmp.length() != f.size && f.size > 0) {
                return "复制字节数不符（应为 " + f.size + "，实为 " + tmp.length() + "）";
            }
            VFile created = createFile(targetDir, f.name,
                    f.dir ? DocumentsContract.Document.MIME_TYPE_DIR
                            : (f.mime.isEmpty() ? "application/octet-stream" : f.mime));
            writeFromLocal(created, tmp);
            if (tmp.length() != f.size && f.size > 0) {
                delete(created);
                return "写入后字节数不符（应为 " + f.size + "，实为 " + tmp.length() + "）";
            }
            if (!delete(f)) {
                delete(created);
                return "复制成功但删除源文件失败（可能被占用）";
            }
            return null;
        } catch (Exception e) {
            return "复制回退失败：" + TextUtil.shortError(e) + "（先前的 moveDocument 也失败：" + moveError + "）";
        } finally {
            if (tmp != null) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        }
    }

    /** 确保目录存在；已存在时原样返回。返回目录 VFile，失败抛异常。 */
    public VFile ensureDir(VFile parent, String name) throws IOException {
        for (VFile c : children(parent)) {
            if (c.dir && c.name.equals(name)) {
                return c;
            }
        }
        return createDir(parent, name);
    }

    /** 在目录中查找同名子项（大小写敏感与 SAF 显示名一致）。 */
    public VFile findChild(VFile dir, String name) {
        for (VFile c : children(dir)) {
            if (c.name.equals(name)) {
                return c;
            }
        }
        return null;
    }

    private static void closeQuietly(Cursor c) {
        if (c != null) {
            try {
                c.close();
            } catch (Exception ignored) {
            }
        }
    }

    private static void closeQuietly(java.io.Closeable c) {
        if (c != null) {
            try {
                c.close();
            } catch (Exception ignored) {
            }
        }
    }
}
