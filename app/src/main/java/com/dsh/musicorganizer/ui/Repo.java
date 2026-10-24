package com.dsh.musicorganizer.ui;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.Uri;

import com.dsh.musicorganizer.core.SettingsBackup;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.TagFill;
import com.dsh.musicorganizer.core.TrackGroup;
import com.dsh.musicorganizer.core.VFile;
import com.dsh.musicorganizer.net.Endpoints;
import com.dsh.musicorganizer.net.MbClient;

import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** 全局仓库：目录树授权、设置、扫描结果、在线客户端。 */
public final class Repo implements Endpoints.Config {

    /** 接口地址覆盖的偏好键前缀 */
    private static final String KEY_URL = "ep:";
    private static final String KEY_ON = "ep_on:";

    private static Repo instance;

    public MbClient mb = new MbClient();
    public Storage storage = null;
    public List<TrackGroup> lastGroups = new ArrayList<TrackGroup>();
    public List<VFile> lastFiles = new ArrayList<VFile>();
    /** 最近一次扫描的统计（曲目 / 歌词 / 跳过数），整理页的提示文案要用。 */
    public com.dsh.musicorganizer.core.ScanStats lastStats;
    /**
     * 最近一次扫描的时间戳（0 = 没扫过）。
     *
     * <p>放在仓库而不是 MainActivity 的字段里：换主题 / 转屏会 {@code recreate()}，
     * Activity 字段全部归零，而扫描结果还在（单例），于是摘要会丢掉「上次扫描 3 分钟前」。
     */
    public long lastScanAt;
    public final List<String[]> logLines = new ArrayList<String[]>(); // {level, message}

    private Context appContext;

    private Repo() {
    }

    public static synchronized Repo get(Context ctx) {
        if (instance == null) {
            instance = new Repo();
        }
        instance.appContext = ctx.getApplicationContext();
        return instance;
    }

    private SharedPreferences prefs() {
        return appContext.getSharedPreferences("mo_settings", Context.MODE_PRIVATE);
    }

    public Uri treeUri() {
        String s = prefs().getString("tree_uri", "");
        if (s.isEmpty()) {
            return null;
        }
        try {
            return Uri.parse(s);
        } catch (Exception e) {
            return null;
        }
    }

    public void saveTreeUri(Uri uri) {
        prefs().edit().putString("tree_uri", uri.toString()).apply();
    }

    public void clearTreeUri() {
        prefs().edit().remove("tree_uri").apply();
        storage = null;
    }

    /**
     * 已选目录的持久授权还在不在。
     *
     * <p><b>只读系统记录，不抛异常</b>——这是关键。旧代码在启动时直接
     * {@code takePersistableUriPermission()} 再 catch 一切异常后清掉目录，
     * 而 {@code recreate()}（换主题 / 转屏 / 深色开关）后 Activity 的 Intent 不再带授权，
     * 部分机型会抛 {@code SecurityException: No persistable permission grants found}，
     * 于是「换一次主题就丢一次目录」。判断授权是否还在应当查这张表，而不是去 take。
     */
    public boolean hasTreeAccess() {
        Uri uri = treeUri();
        if (uri == null) {
            return false;
        }
        try {
            List<android.content.UriPermission> list =
                    appContext.getContentResolver().getPersistedUriPermissions();
            for (android.content.UriPermission p : list) {
                if (p.isReadPermission() && uri.equals(p.getUri())) {
                    return true;
                }
            }
        } catch (Throwable ignored) {
            // 查询本身失败（极少数 ROM）：当作「不知道」，由调用方决定怎么说
        }
        return false;
    }

    /**
     * 尽力补一次持久授权（幂等）。
     *
     * <p>失败**不清目录**：清掉之后用户只能重新选，而重选需要的操作代价远高于让设置留着。
     *
     * @return 补完之后是否可用
     */
    public boolean ensureTreeAccess() {
        Uri uri = treeUri();
        if (uri == null) {
            return false;
        }
        if (hasTreeAccess()) {
            return true;
        }
        try {
            appContext.getContentResolver().takePersistableUriPermission(uri,
                    android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
                            | android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        } catch (Throwable ignored) {
            // 补不上就算了，保持目录设置不动
        }
        return hasTreeAccess();
    }

    /** 打开（或复用）目录树会话。 */
    public Storage openStorage() throws IOException {
        if (storage != null) {
            return storage;
        }
        Uri uri = treeUri();
        if (uri == null) {
            throw new IOException("尚未选择音乐目录");
        }
        storage = new Storage(appContext.getContentResolver(), uri);
        return storage;
    }

    public String treeDisplayName() {
        Uri uri = treeUri();
        if (uri == null) {
            return "未选择目录";
        }
        try {
            String id = android.provider.DocumentsContract.getTreeDocumentId(uri);
            int idx = id.indexOf(':');
            return idx >= 0 ? "/" + id.substring(idx + 1) : id;
        } catch (Exception e) {
            return uri.toString();
        }
    }

    // ---- 设置 ----

    public boolean bool(String key, boolean def) {
        return prefs().getBoolean(key, def);
    }

    public void setBool(String key, boolean value) {
        prefs().edit().putBoolean(key, value).apply();
    }

    public int intVal(String key, int def) {
        return prefs().getInt(key, def);
    }

    public void setInt(String key, int value) {
        prefs().edit().putInt(key, value).apply();
    }

    /** 时间戳这类大数（毫秒）必须用 long，int 存不下。 */
    public long longVal(String key, long def) {
        try {
            return prefs().getLong(key, def);
        } catch (ClassCastException e) {
            // 早期版本可能把它存成了别的类型，读不动就按「没有」处理
            return def;
        }
    }

    public void setLong(String key, long value) {
        prefs().edit().putLong(key, value).apply();
    }

    public String str(String key, String def) {
        try {
            String s = prefs().getString(key, def);
            return s == null ? def : s;
        } catch (ClassCastException e) {
            return def;
        }
    }

    public void setStr(String key, String value) {
        if (value == null) {
            prefs().edit().remove(key).apply();
        } else {
            prefs().edit().putString(key, value).apply();
        }
    }

    // ---- 更新检查 ----

    /** 启动时自动检查更新（每天最多一次）。 */
    public static final String KEY_UPDATE_AUTO = "update_auto";
    /** 上次检查时间（毫秒时间戳；设备相关，不进设置备份）。 */
    public static final String KEY_UPDATE_LAST = "update_last_check";
    /** 上次查到的远端版本 tag（用于离线时也能提示「有新版本」）。 */
    public static final String KEY_UPDATE_TAG = "update_latest";

    // ---- 字段写入策略（TagFill 三态）----

    private static final String KEY_FIELD_PREFIX = "fp:";

    /** 用户显式设置过的字段策略（只含设置过的字段；未设置不在此表）。 */
    public Map<String, Integer> tagFieldModes() {
        Map<String, Integer> m = new LinkedHashMap<String, Integer>();
        for (String f : TagFill.CANDIDATE_FIELDS) {
            int v = intVal(KEY_FIELD_PREFIX + f, -1);
            if (v >= TagFill.DISABLED && v <= TagFill.OVERWRITE) {
                m.put(f, v);
            }
        }
        return m;
    }

    public void setTagFieldMode(String field, int mode) {
        setInt(KEY_FIELD_PREFIX + field, mode);
    }

    /** 清除所有字段级自定义，恢复「跟随全局覆盖开关」。 */
    public void clearTagFieldModes() {
        SharedPreferences.Editor ed = prefs().edit();
        for (String f : TagFill.CANDIDATE_FIELDS) {
            ed.remove(KEY_FIELD_PREFIX + f);
        }
        ed.apply();
    }

    // ---- 接口地址（Endpoints.Config 实现）----

    @Override
    public String override(String endpointKey) {
        return prefs().getString(KEY_URL + endpointKey, null);
    }

    @Override
    public boolean enabled(String sourceKey) {
        return prefs().getBoolean(KEY_ON + sourceKey, true);
    }

    @Override
    public void setOverride(String endpointKey, String url) {
        if (url == null || url.trim().isEmpty()) {
            prefs().edit().remove(KEY_URL + endpointKey).apply();
        } else {
            prefs().edit().putString(KEY_URL + endpointKey, url.trim()).apply();
        }
    }

    @Override
    public void setEnabled(String sourceKey, boolean enabled) {
        prefs().edit().putBoolean(KEY_ON + sourceKey, enabled).apply();
    }

    // ---- 日志 ----

    public synchronized void log(String message, String level) {
        synchronized (logLines) {
            logLines.add(new String[]{level, message});
            while (logLines.size() > 500) {
                logLines.remove(0);
            }
        }
    }

    public synchronized List<String[]> snapshotLogs() {
        synchronized (logLines) {
            return new ArrayList<String[]>(logLines);
        }
    }

    // ---- 设置备份 / 恢复（core/SettingsBackup 的数据来源与写回目标）----

    /** 日志落盘目录（崩溃留痕与导出日志共用）。 */
    public java.io.File logDir() {
        return new java.io.File(appContext.getFilesDir(), "logs");
    }

    /**
     * 导出可备份的设置：只取白名单键，且按类别归一类型。
     * 设备相关的键（`tree_uri` 目录授权、`notif_asked`）不在白名单里，自然被排除。
     */
    public Map<String, Object> exportSettings() {
        Map<String, Object> out = new LinkedHashMap<String, Object>();
        List<String> ignored = new ArrayList<String>();
        for (Map.Entry<String, ?> e : prefs().getAll().entrySet()) {
            String key = e.getKey();
            if (e.getValue() == null || !SettingsBackup.isKnownKey(key)) {
                continue;
            }
            Object clean = SettingsBackup.sanitize(key, e.getValue(), ignored);
            if (clean != null) {
                out.put(key, clean);
            }
        }
        return out;
    }

    /** 把校验过的设置逐项写回；返回写入的项数。未出现在 values 里的键保持不动。 */
    /**
     * 恢复默认设置：把所有**可备份的设置键**删掉，让各处读取时的默认值自然生效。
     *
     * <p>刻意不碰这些：目录授权（`tree_uri`，删了要重新选目录）、扫描快照与扫描结果、
     * 写入历史（Journal 属于文件）、日志。换句话说「恢复默认」只还原偏好，不动数据。
     *
     * @return 实际清掉的键数
     */
    public int resetSettings() {
        SharedPreferences p = prefs();
        List<String> remove = new ArrayList<String>();
        for (String k : p.getAll().keySet()) {
            if (SettingsBackup.isKnownKey(k)) {
                remove.add(k);
            }
        }
        if (remove.isEmpty()) {
            return 0;
        }
        SharedPreferences.Editor e = p.edit();
        for (String k : remove) {
            e.remove(k);
        }
        e.apply();
        return remove.size();
    }

    public int importSettings(Map<String, Object> values) {
        if (values == null || values.isEmpty()) {
            return 0;
        }
        SharedPreferences.Editor ed = prefs().edit();
        int n = 0;
        for (Map.Entry<String, Object> e : values.entrySet()) {
            String key = e.getKey();
            Object v = e.getValue();
            if (SettingsBackup.kindOf(key) == null || v == null) {
                continue;
            }
            if (v instanceof Boolean) {
                ed.putBoolean(key, ((Boolean) v).booleanValue());
            } else if (v instanceof Integer) {
                ed.putInt(key, ((Integer) v).intValue());
            } else {
                ed.putString(key, String.valueOf(v));
            }
            n++;
        }
        ed.apply();
        return n;
    }
}
