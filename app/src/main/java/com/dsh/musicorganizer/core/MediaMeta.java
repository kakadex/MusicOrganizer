package com.dsh.musicorganizer.core;

import android.content.ContentResolver;
import android.content.Context;
import android.media.MediaMetadataRetriever;
import android.net.Uri;

import java.util.HashMap;
import java.util.Map;

/**
 * 时长与兜底标签读取 —— 基于 Android 框架的 MediaMetadataRetriever（零依赖）。
 * 结果按 (docId, size, lastModified) 缓存，对应 Python 版三层兜底的缓存语义。
 */
public final class MediaMeta {

    private MediaMeta() {
    }

    /** 应用 Context（MediaMetadataRetriever.setDataSource 需要 Context 而非 ContentResolver）。
     *  由 MainActivity.onCreate 注入，先于任何扫描/读取。 */
    private static Context sContext;

    public static void init(Context ctx) {
        if (ctx != null) {
            sContext = ctx.getApplicationContext();
        }
    }

    /** 并发安全：批量任务会多线程同时查时长/标签。ConcurrentHashMap 不允许 null 值，
     *  所以「查过但没有时长」用 0 占位，读出时再转回 null。 */
    private static final Map<String, Double> DURATION_CACHE =
            new java.util.concurrent.ConcurrentHashMap<String, Double>();
    private static final Map<String, Tags> TAG_CACHE =
            new java.util.concurrent.ConcurrentHashMap<String, Tags>();
    private static final int CACHE_LIMIT = 4096;

    /**
     * 丢掉某个文件的缓存（写入标签后必须调）。
     *
     * <p>缓存键是 {@code docId|size|lastModified}，而 VFile 的这三个字段是 final —— 写入磁盘后
     * 对象里的 size/mtime 不会变，键也就不会变。不主动清理的话，写完再读会命中写入前的旧值，
     * 事务层的「回读校验」必然判失败（曾经导致整批 110 首全部误报写入失败）。
     *
     * @param docId 文档 ID；传 {@code null} 清空全部
     */
    public static void invalidate(String docId) {
        if (docId == null) {
            DURATION_CACHE.clear();
            TAG_CACHE.clear();
            return;
        }
        String prefix = docId + "|";
        java.util.Iterator<String> it;
        for (it = DURATION_CACHE.keySet().iterator(); it.hasNext(); ) {
            if (it.next().startsWith(prefix)) {
                it.remove();
            }
        }
        for (it = TAG_CACHE.keySet().iterator(); it.hasNext(); ) {
            if (it.next().startsWith(prefix)) {
                it.remove();
            }
        }
    }

    /** 读取音频时长（秒）；失败返回 null。 */
    public static Double duration(ContentResolver resolver, Uri uri, String cacheKey) {
        Double cached = DURATION_CACHE.get(cacheKey);
        if (cached != null) {
            return cached > 0 ? cached : null;
        }
        MediaMetadataRetriever mmr = new MediaMetadataRetriever();
        try {
            mmr.setDataSource(sContext, uri);
            String v = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
            double sec = v == null ? 0 : Double.parseDouble(v) / 1000.0;
            Double result = sec > 0 ? Double.valueOf(sec) : null;
            if (DURATION_CACHE.size() > CACHE_LIMIT) {
                DURATION_CACHE.clear();
            }
            DURATION_CACHE.put(cacheKey, result == null ? Double.valueOf(0) : result);
            return result;
        } catch (Exception e) {
            return null;
        } finally {
            try {
                mmr.release();
            } catch (Exception ignored) {
            }
        }
    }

    /**
     * 内嵌封面字节（框架解析，v0.1.54）。
     *
     * <p>为什么需要它：我们自己的 {@code CoverReader} 是手写解析，遇到少见的标签写法
     * （非同步安全帧长、扩展帧、超大标签）会读不到 —— 但系统的
     * {@code MediaMetadataRetriever.getEmbeddedPicture()} 往往还能拿到。
     * 自研解析失败时用它兜底，避免「文件明明有封面，列表里却写着无封面」。
     *
     * @return 图片字节；没有或读不出返回 {@code null}
     */
    public static byte[] embeddedPicture(ContentResolver resolver, Uri uri) {
        if (resolver == null || uri == null) {
            return null;
        }
        MediaMetadataRetriever mmr = new MediaMetadataRetriever();
        android.os.ParcelFileDescriptor pfd = null;
        try {
            pfd = resolver.openFileDescriptor(uri, "r");
            if (pfd == null) {
                return null;
            }
            mmr.setDataSource(pfd.getFileDescriptor());
            byte[] art = mmr.getEmbeddedPicture();
            return art == null || art.length == 0 ? null : art;
        } catch (Throwable ignored) {
            return null;
        } finally {
            if (pfd != null) {
                try {
                    pfd.close();
                } catch (Throwable ignored) {
                    // 关不掉不影响结果
                }
            }
            try {
                mmr.release();
            } catch (Throwable ignored) {
                // 部分系统版本 release() 抛 IOException
            }
        }
    }

    /** 兜底标签读取（自身解析失败或为空时）。 */    public static Tags basicTags(ContentResolver resolver, Uri uri, String cacheKey) {
        Tags cached = TAG_CACHE.get(cacheKey);
        if (cached != null) {
            return cached;
        }
        Tags tags = new Tags();
        MediaMetadataRetriever mmr = new MediaMetadataRetriever();
        try {
            mmr.setDataSource(sContext, uri);
            putIfNotEmpty(tags, "title", mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE));
            putIfNotEmpty(tags, "artist", mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST));
            if (tags.get("artist").isEmpty()) {
                putIfNotEmpty(tags, "artist", mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST));
            }
            putIfNotEmpty(tags, "album", mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUM));
            putIfNotEmpty(tags, "genre", mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_GENRE));
            String year = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_YEAR);
            if (year != null && year.length() > 4) {
                year = year.substring(0, 4);
            }
            if (year != null && !year.isEmpty()) {
                tags.put("year", year);
            }
        } catch (Exception ignored) {
        } finally {
            try {
                mmr.release();
            } catch (Exception ignored) {
            }
        }
        if (TAG_CACHE.size() > CACHE_LIMIT) {
            TAG_CACHE.clear();
        }
        TAG_CACHE.put(cacheKey, tags);
        return tags;
    }

    private static void putIfNotEmpty(Tags tags, String key, String value) {
        if (value != null && !value.trim().isEmpty()) {
            tags.put(key, value.trim());
        }
    }
}
