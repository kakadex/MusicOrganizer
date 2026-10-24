package com.dsh.musicorganizer.core;

import android.Manifest;
import android.content.ContentResolver;
import android.content.Context;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;

import java.util.ArrayList;
import java.util.List;

/**
 * 系统媒体库（MediaStore）扫描 —— 解决「SAF 授权拿不到 /Download」这个死角（v0.1.42）。
 *
 * <p>为什么要它：Android 11+ 不让 SAF 选「下载」这类根目录，用户明明能看到歌，应用里却扫不到。
 * 系统媒体库有特权，能把这些文件列出来（只读元数据：标题 / 艺人 / 专辑 / 时长 / 大小 / 路径）。
 *
 * <p><b>能力边界（很重要）</b>：MediaStore 给的是 {@code content://media/...}，没有 document URI，
 * 我们的事务层（{@code Storage}/{@code TagTransaction}）全部基于 DocumentsContract，
 * 所以 **不能直接对媒体库条目写标签 / 改名 / 移动**。能做的是：
 * 列出 → 筛选 → **导入到已授权的 SAF 目录**（复制字节过去），导入后就是普通文件，全套功能可用。
 *
 * <p>权限：Android 13+ 用 {@code READ_MEDIA_AUDIO}；≤12 用 {@code READ_EXTERNAL_STORAGE}。
 */
public final class MediaStoreScan {

    private MediaStoreScan() {
    }

    /** 需要申请的权限（按系统版本选一个）。 */
    public static String permission() {
        if (Build.VERSION.SDK_INT >= 33) {
            return "android.permission.READ_MEDIA_AUDIO";
        }
        return Manifest.permission.READ_EXTERNAL_STORAGE;
    }

    public static boolean hasPermission(Context ctx) {
        try {
            return ctx.checkSelfPermission(permission()) == PackageManager.PERMISSION_GRANTED;
        } catch (Exception e) {
            return false;
        }
    }

    /** 一条媒体库记录的 content uri（导入时读字节用）。 */
    public static Uri uriOf(MediaTrack t) {
        return Uri.withAppendedPath(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                String.valueOf(t.id));
    }

    /**
     * 扫一遍系统媒体库。
     *
     * @param minDurationMs 过滤掉短音频（铃声 / 提示音），传 0 不过滤
     * @return 按标题排序的列表；没权限或查询失败返回空表
     */
    public static List<MediaTrack> scan(Context ctx, long minDurationMs) {
        List<MediaTrack> out = new ArrayList<MediaTrack>();
        if (ctx == null || !hasPermission(ctx)) {
            return out;
        }
        ContentResolver resolver = ctx.getContentResolver();
        String[] projection = new String[]{
                MediaStore.Audio.Media._ID,
                MediaStore.Audio.Media.TITLE,
                MediaStore.Audio.Media.ARTIST,
                MediaStore.Audio.Media.ALBUM,
                MediaStore.Audio.Media.DURATION,
                MediaStore.Audio.Media.SIZE,
                MediaStore.Audio.Media.MIME_TYPE,
                MediaStore.Audio.Media.DATA,
        };
        String selection = null;
        List<String> args = new ArrayList<String>();
        if (minDurationMs > 0) {
            selection = MediaStore.Audio.Media.DURATION + ">=?";
            args.add(String.valueOf(minDurationMs));
        }
        Cursor c = null;
        try {
            c = resolver.query(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, projection, selection,
                    args.isEmpty() ? null : args.toArray(new String[0]),
                    MediaStore.Audio.Media.TITLE + " COLLATE NOCASE ASC");
            if (c == null) {
                return out;
            }
            int idIdx = c.getColumnIndex(MediaStore.Audio.Media._ID);
            int titleIdx = c.getColumnIndex(MediaStore.Audio.Media.TITLE);
            int artistIdx = c.getColumnIndex(MediaStore.Audio.Media.ARTIST);
            int albumIdx = c.getColumnIndex(MediaStore.Audio.Media.ALBUM);
            int durIdx = c.getColumnIndex(MediaStore.Audio.Media.DURATION);
            int sizeIdx = c.getColumnIndex(MediaStore.Audio.Media.SIZE);
            int mimeIdx = c.getColumnIndex(MediaStore.Audio.Media.MIME_TYPE);
            int dataIdx = c.getColumnIndex(MediaStore.Audio.Media.DATA);
            while (c.moveToNext()) {
                MediaTrack t = new MediaTrack();
                t.id = idIdx >= 0 ? c.getLong(idIdx) : 0;
                t.title = titleIdx >= 0 ? safe(c.getString(titleIdx)) : "";
                t.artist = artistIdx >= 0 ? safe(c.getString(artistIdx)) : "";
                t.album = albumIdx >= 0 ? safe(c.getString(albumIdx)) : "";
                t.durationMs = durIdx >= 0 ? c.getLong(durIdx) : 0;
                t.size = sizeIdx >= 0 ? c.getLong(sizeIdx) : 0;
                t.mime = mimeIdx >= 0 ? safe(c.getString(mimeIdx)) : "";
                t.path = dataIdx >= 0 ? safe(c.getString(dataIdx)) : "";
                t.folder = MediaTrack.folderOf(t.path);
                if (t.id > 0) {
                    out.add(t);
                }
            }
        } catch (Exception ignored) {
            // 权限被撤、provider 异常：当作扫不到，不抛给界面
        } finally {
            if (c != null) {
                try {
                    c.close();
                } catch (Exception ignored) {
                }
            }
        }
        return out;
    }

    /** Android 里 ARTIST 列经常是字面量 {@code <unknown>}，当成空。 */
    private static String safe(String value) {
        if (value == null) {
            return "";
        }
        String s = value.trim();
        if (s.equals("<unknown>") || s.equalsIgnoreCase("unknown")) {
            return "";
        }
        return s;
    }
}
