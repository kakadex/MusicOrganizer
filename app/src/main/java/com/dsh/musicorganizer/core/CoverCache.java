package com.dsh.musicorganizer.core;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 封面落盘缓存（v0.1.75）。
 *
 * <p><b>为什么需要</b>：封面位图只存在内存 LRU 里，进程一退就没了。下次打开库页面
 * 每首都要重新走一遍 SAF：复制文件头（最多 2MB）→ 解析标签 → 抠出图片 → 缩放解码。
 * 一千多首就是一千多次 SAF 读取，冷启动后第一批封面要等好几秒才冒出来。
 *
 * <p>这里把**已经缩好的小图**（{@link #STORE_PX} 见方的 JPEG，约 15KB）按
 * 「docId + 文件大小 + 修改时间」落盘。命中时只需读一个本地小文件，完全不碰 SAF。
 * 键里带大小和修改时间，所以换了封面 / 重新打标签 / 换了文件，旧缓存自动失效，
 * 不需要任何手动清理逻辑；孤儿文件靠 {@link #prune} 按容量淘汰。
 *
 * <p>只缓存**有封面**的结果。读不到封面时不写"空标记"——否则用户往文件夹里补一张
 * {@code cover.jpg}，要等缓存过期才会显示出来。
 *
 * <p>线程：所有方法都可以在后台线程调用；{@link #load} 会解码，别在主线程调。
 */
public final class CoverCache {

    /** 缓存目录名（放在 App 私有 cacheDir 下，系统空间不足时可自行回收）。 */
    private static final String DIR_NAME = "covers";

    /**
     * 落盘尺寸：列表封面最宽约 48dp（3x 屏 ≈144px），存 192px 足够清晰，
     * 又比原图小一到两个数量级。
     */
    private static final int STORE_PX = 192;

    /** JPEG 质量：85 在这个尺寸下肉眼无损，体积约 12~20KB。 */
    private static final int QUALITY = 85;

    /** 缓存总量上限：48MB ≈ 两三千首；超了按最久未用淘汰到 7 成。 */
    private static final long CAP_BYTES = 48L * 1024L * 1024L;

    /** 每写这么多次检查一次容量，避免每首都去 listFiles。 */
    private static final int PRUNE_EVERY = 64;

    private static final AtomicInteger SAVES = new AtomicInteger();

    /**
     * 编码结果备忘：图片字节摘要 → 编好的 JPEG。
     *
     * <p>同一个文件夹里的十几首歌往往共用同一张 {@code cover.jpg}（{@link #save} 每首都会
     * 被调用一次）。没有这张表的话，同一张图会被解码 + 压缩十几次，纯浪费 CPU。
     * 只留几十条，几十 KB 一条。
     */
    private static final Map<String, byte[]> MEMO = new HashMap<String, byte[]>();

    private static final int MEMO_LIMIT = 64;

    private CoverCache() {
    }

    /** 缓存目录（不存在就建）。 */
    public static File dir(Context ctx) {
        File d = new File(ctx.getCacheDir(), DIR_NAME);
        if (!d.isDirectory()) {
            //noinspection ResultOfMethodCallIgnored
            d.mkdirs();
        }
        return d;
    }

    /**
     * 缓存键：docId 的摘要 + 大小 + 修改时间。
     *
     * <p>用摘要而不是原 docId，是因为 docId 里带 {@code /} 和 {@code :}，
     * 长路径拼成文件名会超长。摘要只用来定文件名，同目录下仍靠 size/mtime 区分版本。
     */
    static String key(VFile f) {
        if (f == null || f.docId == null) {
            return null;
        }
        return md5(f.docId) + "_" + f.size + "_" + f.lastModified;
    }

    /**
     * 读缓存。
     *
     * @return 解码好的位图；没有缓存返回 {@code null}（调用方应回退到读文件）
     */
    public static Bitmap load(Context ctx, VFile f) {
        String k = key(f);
        if (k == null || ctx == null) {
            return null;
        }
        File file = new File(dir(ctx), k + ".jpg");
        if (!file.isFile() || file.length() <= 0) {
            return null;
        }
        try {
            Bitmap bmp = BitmapFactory.decodeFile(file.getAbsolutePath());
            if (bmp != null) {
                // 兼作「最近使用」时间戳，淘汰时按它排序
                //noinspection ResultOfMethodCallIgnored
                file.setLastModified(System.currentTimeMillis());
            }
            return bmp;
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * 把封面原图（内嵌图 / 目录封面图）缩好落盘。
     *
     * @param art 原始图片字节；空或解不出来直接忽略
     */
    public static void save(Context ctx, VFile f, byte[] art) {
        if (ctx == null || f == null || art == null || art.length == 0) {
            return;
        }
        String k = key(f);
        if (k == null) {
            return;
        }
        String digest = md5(art);
        byte[] encoded;
        synchronized (MEMO) {
            encoded = MEMO.get(digest);
        }
        if (encoded == null) {
            // 同一张图（同目录封面）只解码 + 压缩一次
            Bitmap bmp = decodeScaled(art, STORE_PX);
            if (bmp == null) {
                return;
            }
            try {
                encoded = encode(bmp);
            } finally {
                bmp.recycle();
            }
            if (encoded == null) {
                return;
            }
            synchronized (MEMO) {
                if (MEMO.size() >= MEMO_LIMIT) {
                    MEMO.clear();
                }
                MEMO.put(digest, encoded);
            }
        }
        write(ctx, k, encoded);
    }

    /** 已经解码好的位图直接落盘（省一次解码）。 */
    public static void saveBitmap(Context ctx, VFile f, Bitmap bmp) {
        if (ctx == null || f == null || bmp == null || bmp.isRecycled()) {
            return;
        }
        String k = key(f);
        if (k == null) {
            return;
        }
        Bitmap small = scaleTo(bmp, STORE_PX);
        try {
            byte[] encoded = encode(small);
            if (encoded != null) {
                write(ctx, k, encoded);
            }
        } catch (Throwable ignored) {
            // 落盘失败只是没缓存，下次再读文件即可，不能影响界面
        } finally {
            if (small != bmp) {
                small.recycle();
            }
        }
    }

    /** 清空全部缓存（换目录 / 排查问题时用）。 */
    public static void clear(Context ctx) {
        if (ctx == null) {
            return;
        }
        try {
            File[] fs = dir(ctx).listFiles();
            if (fs == null) {
                return;
            }
            for (File f : fs) {
                //noinspection ResultOfMethodCallIgnored
                f.delete();
            }
        } catch (Throwable ignored) {
        }
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    private static void write(Context ctx, String k, byte[] data) {
        File d = dir(ctx);
        File out = new File(d, k + ".jpg");
        File tmp = new File(d, k + ".tmp");
        FileOutputStream fos = null;
        try {
            fos = new FileOutputStream(tmp);
            fos.write(data);
            fos.flush();
            fos.close();
            fos = null;
            //noinspection ResultOfMethodCallIgnored
            out.delete();
            if (!tmp.renameTo(out)) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
                return;
            }
            if (SAVES.incrementAndGet() % PRUNE_EVERY == 0) {
                prune(ctx);
            }
        } catch (Throwable t) {
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
        } finally {
            if (fos != null) {
                try {
                    fos.close();
                } catch (Throwable ignored) {
                }
            }
        }
    }

    /** 超过容量上限就按「最近使用时间」淘汰到 7 成。 */
    private static void prune(Context ctx) {
        try {
            File[] fs = dir(ctx).listFiles();
            if (fs == null || fs.length == 0) {
                return;
            }
            long total = 0L;
            for (File f : fs) {
                total += f.length();
            }
            if (total <= CAP_BYTES) {
                return;
            }
            final long target = CAP_BYTES * 7L / 10L;
            Arrays.sort(fs, new Comparator<File>() {
                @Override
                public int compare(File a, File b) {
                    long x = a.lastModified();
                    long y = b.lastModified();
                    return x < y ? -1 : (x > y ? 1 : 0);
                }
            });
            for (File f : fs) {
                if (total <= target) {
                    break;
                }
                long len = f.length();
                if (f.delete()) {
                    total -= len;
                }
            }
        } catch (Throwable ignored) {
        }
    }

    /** 按 BitmapFactory 采样解码到「长边约 target」——不先解全图，省内存也省时间。 */
    private static Bitmap decodeScaled(byte[] art, int target) {
        try {
            BitmapFactory.Options probe = new BitmapFactory.Options();
            probe.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(art, 0, art.length, probe);
            int w = probe.outWidth;
            int h = probe.outHeight;
            if (w <= 0 || h <= 0) {
                return null;
            }
            int sample = 1;
            while (Math.max(w, h) / (sample * 2) >= target) {
                sample *= 2;
            }
            BitmapFactory.Options real = new BitmapFactory.Options();
            real.inSampleSize = sample;
            return BitmapFactory.decodeByteArray(art, 0, art.length, real);
        } catch (Throwable t) {
            return null;
        }
    }

    /** 长边超过 target 就等比缩小；本来就小就原样返回引用（调用方负责判断是否 recycle）。 */
    private static Bitmap scaleTo(Bitmap src, int target) {
        int w = src.getWidth();
        int h = src.getHeight();
        int max = Math.max(w, h);
        if (max <= target * 3 / 2 || w <= 0 || h <= 0) {
            return src;
        }
        float ratio = (float) target / (float) max;
        int nw = Math.max(1, Math.round(w * ratio));
        int nh = Math.max(1, Math.round(h * ratio));
        try {
            return Bitmap.createScaledBitmap(src, nw, nh, true);
        } catch (Throwable t) {
            return src;
        }
    }

    private static String md5(String s) {
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            return hex(md.digest(s.getBytes("UTF-8")));
        } catch (Throwable t) {
            // 极端情况下（Provider 被替换）退化成 hashCode，仍然能当文件名用
            return Integer.toHexString(s.hashCode());
        }
    }

    private static String md5(byte[] data) {
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            return hex(md.digest(data));
        } catch (Throwable t) {
            return Integer.toHexString(Arrays.hashCode(data));
        }
    }

    private static String hex(byte[] digest) {
        StringBuilder sb = new StringBuilder(digest.length * 2);
        for (byte b : digest) {
            int v = b & 0xFF;
            if (v < 16) {
                sb.append('0');
            }
            sb.append(Integer.toHexString(v));
        }
        return sb.toString();
    }

    /** 位图 → JPEG 字节；失败返回 null。 */
    private static byte[] encode(Bitmap bmp) {
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream(16 * 1024);
            if (!bmp.compress(Bitmap.CompressFormat.JPEG, QUALITY, bos)) {
                return null;
            }
            return bos.toByteArray();
        } catch (Throwable t) {
            return null;
        }
    }
}
