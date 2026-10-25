package com.dsh.musicorganizer.core;

import android.content.Context;
import android.media.MediaScannerConnection;

import java.util.ArrayList;
import java.util.List;

/**
 * 写完标签后通知系统媒体库刷新（v0.1.80）。
 *
 * <p><b>为什么必须有这一步</b>：很多播放器（包括系统自带的）读的不是文件标签，
 * 而是**系统媒体库**里那份索引。我们改完文件标签，媒体库还是旧的，用户回到播放器
 * 一看还是老名字、老封面 —— 会以为我们没写进去。
 *
 * <p><b>SAF 下怎么拿到路径</b>：SAF 给的是 document id（{@code primary:Music/a.mp3}），
 * 系统扫描接口要的是文件路径。这里按卷号还原：
 * <ul>
 *   <li>{@code primary:rel/path} → {@code /storage/emulated/0/rel/path}</li>
 *   <li>{@code 1234-ABCD:rel/path}（SD 卡）→ {@code /storage/1234-ABCD/rel/path}</li>
 * </ul>
 * 还原不出来（第三方网盘、非标准 provider）就**静默跳过** —— 刷新只是锦上添花，
 * 绝不能因为它失败而让写标签报错。
 */
public final class MediaRefresh {

    private MediaRefresh() {
    }

    /** 通知系统媒体库：这个文件变了。失败静默。 */
    public static void scan(Context ctx, VFile f) {
        if (ctx == null || f == null || f.dir) {
            return;
        }
        String path = pathOf(f);
        if (path == null) {
            return;
        }
        try {
            MediaScannerConnection.scanFile(ctx, new String[]{path}, null, null);
        } catch (Throwable ignored) {
            // 系统扫描服务不可用（极少数精简 ROM）：不影响主流程
        }
    }

    /** 批量刷新（整理搬动文件后一次扫完，比逐个扫省事）。 */
    public static void scanAll(Context ctx, List<VFile> files) {
        if (ctx == null || files == null || files.isEmpty()) {
            return;
        }
        List<String> paths = new ArrayList<String>(files.size());
        for (VFile f : files) {
            String p = pathOf(f);
            if (p != null) {
                paths.add(p);
            }
        }
        if (paths.isEmpty()) {
            return;
        }
        try {
            MediaScannerConnection.scanFile(ctx, paths.toArray(new String[0]), null, null);
        } catch (Throwable ignored) {
        }
    }

    /**
     * document id → 文件路径。
     *
     * @return 还原不出来返回 {@code null}
     */
    static String pathOf(VFile f) {
        if (f == null || f.docId == null) {
            return null;
        }
        int colon = f.docId.indexOf(':');
        if (colon <= 0 || colon == f.docId.length() - 1) {
            return null;
        }
        String volume = f.docId.substring(0, colon);
        String rel = f.docId.substring(colon + 1);
        if (rel.startsWith("/")) {
            rel = rel.substring(1);
        }
        if (volume.isEmpty() || rel.isEmpty()) {
            return null;
        }
        if ("primary".equalsIgnoreCase(volume)) {
            return "/storage/emulated/0/" + rel;
        }
        return "/storage/" + volume + "/" + rel;
    }
}
