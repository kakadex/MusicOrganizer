package com.dsh.musicorganizer.ui;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Looper;
import android.provider.DocumentsContract;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.ScrollView;
import android.widget.Toast;

import com.dsh.musicorganizer.R;
import com.dsh.musicorganizer.core.AppLog;
import com.dsh.musicorganizer.core.AppUpdate;
import com.dsh.musicorganizer.core.BatchMemory;
import com.dsh.musicorganizer.core.CancelToken;
import com.dsh.musicorganizer.core.CoverCache;
import com.dsh.musicorganizer.core.Logger;
import com.dsh.musicorganizer.core.MediaMeta;
import com.dsh.musicorganizer.core.Organizer;
import com.dsh.musicorganizer.core.Progress;
import com.dsh.musicorganizer.core.ScanMerge;
import com.dsh.musicorganizer.core.Scanner;
import com.dsh.musicorganizer.core.SettingsBackup;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.TaskControl;
import com.dsh.musicorganizer.core.TextUtil;
import com.dsh.musicorganizer.core.Theme;
import com.dsh.musicorganizer.core.TrackGroup;
import com.dsh.musicorganizer.core.VFile;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 主界面：单 Activity + 三页签（整理 / 文件 / 日志），全部程序化布局。
 */
public class MainActivity extends Activity implements Logger {

    private static final int REQ_PICK_TREE = 41;
    /** 导出运行日志（文本） */
    private static final int REQ_EXPORT_LOG = 44;
    /** 导出设置（JSON） */
    private static final int REQ_EXPORT_SETTINGS = 45;
    /** 导入设置（JSON） */
    private static final int REQ_IMPORT_SETTINGS = 46;
    /** 导出曲库清单（CSV） */
    private static final int REQ_EXPORT_CSV = 47;
    /** 读取系统媒体库（v0.1.42） */
    private static final int REQ_MEDIA_PERMISSION = 48;

    // 注意：不能在字段初始化时调用 Repo.get(this) —— 此时 Activity 尚未 attach，
    // getApplicationContext() 为 null，会触发 NPE 导致启动即闪退。
    // 必须在 onCreate（attach 之后）赋值，见下方 onCreate。
    public Repo repo;

    private TextView pathText;
    private TextView statusText;
    /** 顶栏副标题：显示版本号，发现新版本时追加提示（同时是「检查更新」入口）。 */
    private TextView subtitleText;
    private ProgressBar progressBar;
    private FrameLayout content;
    private OrganizePage organizePage;
    private BrowsePage browsePage;
    private SettingsPage settingsPage;
    /**
     * 顶栏三个槽位（左 / 中 / 右），切页时由 {@link #renderHeader()} 重建。
     *
     * <p>用三槽而不是「图标 + 弹簧 + 图标」：左右槽各自固定 44dp，中间那格永远精确居中，
     * 不随两侧内容宽度漂移（主界面齿轮在左、音乐库图标居中、排序在右；
     * 设置页返回箭头在左、标题居中、右侧留空）。
     */
    private LinearLayout headerSlotLeft;
    private LinearLayout headerSlotCenter;
    private LinearLayout headerSlotRight;
    private LinearLayout logPage;
    private android.widget.ListView logList;
    private LogAdapter logAdapter;
    /**
     * 单主界面 + 设置入口：主界面固定为「音乐库」
     * （{@link BrowsePage}），整理 / 日志 / 设置都从右上角齿轮进的设置页里打开，
     * 不再是底部多标签。
     *
     * <p>页索引：0 整理 / 1 音乐库(主) / 2 日志 / 3 设置。
     */
    private int currentTab;
    /** 当前页的偏好键：切换主题会 recreate，靠它回到原来的页。 */
    private static final String KEY_LAST_TAB = "last_tab";

    private ScrollView bootScroll;
    private TextView bootText;

    /** 日志页底部的落盘信息（文件数 / 大小）。 */
    private TextView logStatsText;
    /** 待写入导出文件的文本（SAF 返回后才写，避免用户取消时白算一遍）。 */
    private String pendingExportText;
    private String pendingExportName;

    // 日志面板刷新（v0.1.4）：Repo.logLines 是 LogAdapter 的数据源，必须在主线程追加。
    // 以前在调用线程（基本是后台任务线程）直接 add，再把 notifyDataSetChanged 投递到主线程，
    // 中间那段窗口里 ListView 若正在惯性滑动重排（AbsListView$FlingRunnable → layoutChildren），
    // 就会检测到「条目数变了但没收到通知」并抛 IllegalStateException 闪退。
    private final java.util.ArrayList<String[]> pendingLogs = new java.util.ArrayList<String[]>();
    private boolean logFlushPosted = false;
    private final Runnable logFlush = new Runnable() {
        @Override
        public void run() {
            java.util.List<String[]> batch;
            synchronized (pendingLogs) {
                logFlushPosted = false;
                if (pendingLogs.isEmpty()) {
                    return;
                }
                batch = new java.util.ArrayList<String[]>(pendingLogs);
                pendingLogs.clear();
            }
            if (repo == null) {
                return;
            }
            for (String[] e : batch) {
                repo.log(e[1], e[0]);          // {level, message} → log(message, level)
            }
            if (logAdapter != null) {
                logAdapter.notifyDataSetChanged();
            }
        }
    };

    /** 上一次任务是否被「停止」按钮终止。 */
    private boolean lastTaskStopped = false;

    /**
     * 任务面板：暂停/继续、停止、暂停后预览已获取部分。
     *
     * <p>用 {@link TextView} 小胶囊而不是 {@code Button}：Button 有 48dp 最小高度和 88dp
     * 最小宽度，三个并排会撑爆底栏；胶囊只有一行高，底部状态栏才能固定高度、不抖。
     */
    private TextView btnTaskPause;
    private TextView btnTaskStop;
    private TextView btnTaskPreview;

    /** 「从暂停预览里接管」时，等当前任务收尾后再执行的动作。 */
    private Runnable pendingAfterStop;
    /** 本次停止是用户从「已获取部分」预览里主动接管，匹配任务不应再弹自己的结果。 */
    private boolean partialHandoff;
    /** 主线程定时器（自动重扫的排队用）。 */
    private final android.os.Handler handler =
            new android.os.Handler(android.os.Looper.getMainLooper());
    /** 是否已经排了一次自动重扫（避免连续几次 invalidate 触发多次扫描）。 */
    private boolean rescanPending;

    /** 没有任务在跑时的空令牌，避免调用方判空。 */
    private static final CancelToken IDLE_TOKEN = new CancelToken() {
        @Override
        public boolean isCancelled() {
            return false;
        }
    };

    /** 任务状态变化后刷新底部面板（主线程）。 */
    private final Runnable taskObserver = new Runnable() {
        @Override
        public void run() {
            updateTaskPanel();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        // 系统主题（对话框底色、对话框标题、输入框光标、滚动条）必须跟着应用内的夜间开关走。
        // 页面与卡片颜色是 UiKit 按主题现算的，但「对话框那层底色」由 XML 主题决定 ——
        // 主题一直停在 Light，夜间模式弹出来的就是白底浅字（看不清）。
        // 必须在 super.onCreate() 之前设置：窗口对象在那时才按主题创建。
        android.content.SharedPreferences bootPrefs =
                getSharedPreferences("mo_settings", MODE_PRIVATE);
        final boolean bootDark = bootPrefs.getBoolean("theme_dark", false);
        setTheme(bootDark
                ? com.dsh.musicorganizer.R.style.AppThemeDark
                : com.dsh.musicorganizer.R.style.AppTheme);
        // 色板也要在诊断屏之前装好：showBootScreen() 用的就是 UiKit 的颜色，
        // 晚装一步，夜间模式启动瞬间会闪一下亮色。
        int bootTheme = bootPrefs.getInt("theme_id",
                com.dsh.musicorganizer.core.Theme.LYRICO);
        if (bootTheme < 0 || bootTheme >= com.dsh.musicorganizer.core.Theme.NAMES.length) {
            bootTheme = com.dsh.musicorganizer.core.Theme.LYRICO;
        }
        UiKit.install(bootTheme, bootDark);
        super.onCreate(savedInstanceState);
        // 全面屏必须在任何 setContentView 之前生效，否则第一屏（启动诊断屏）
        // 还会按「让出系统栏」的老模式排版，出现上下两条空带。
        applyEdgeToEdge();
        // 先展示一个保证可见的诊断屏，杜绝"白屏无信息"的歧义
        showBootScreen();

        try {
            boot("【1/4】初始化媒体元数据…");
            MediaMeta.init(this);
            boot("【2/4】加载设置仓库…");
            repo = Repo.get(this); // 必须在 attach 之后调用，保证 appContext 有效
            // 把「用户可改的接口地址」接进网络层：此后所有请求都按设置走
            com.dsh.musicorganizer.net.Endpoints.install(repo);
            // 并发度 / 超时倍率同样要在任何批量开跑之前生效
            com.dsh.musicorganizer.net.NetTuning.apply(
                    repo.intVal(SettingsBackup.KEY_NET_FILES,
                            com.dsh.musicorganizer.net.NetTuning.DEFAULT_FILE_CONCURRENCY),
                    repo.intVal(SettingsBackup.KEY_NET_TIMEOUT,
                            com.dsh.musicorganizer.net.NetTuning.DEFAULT_TIMEOUT_PERCENT));
            // 歌词繁→简开关：默认开，关掉后取到的歌词保持原样
            com.dsh.musicorganizer.core.Lyrics.setSimplify(repo.bool("lyrics_simplify", true));
            // 一次性迁移到「嵌入歌词」模式（v0.1.60）。
            // 早期版本默认只在旁边写 .lrc，很多播放器读不到；现在统一改成
            // 「写 .lrc 的同时嵌入音频标签」，老用户的旧设置也一并升级一次。
            if (!repo.bool("lrc_embed_migrated", false)) {
                repo.setBool("lrc_embed", true);
                repo.setBool("lrc_embed_migrated", true);
            }
            TaskCenter.init(this);
            // 主题：三个方案 × 亮/暗，必须在 buildUi 之前装好，组件按它取色
            int themeId = repo.intVal("theme_id", Theme.LYRICO);
            if (themeId < 0 || themeId >= Theme.NAMES.length) {
                themeId = Theme.LYRICO; // 旧版本残留的主题 id 统一落到简蓝
            }
            UiKit.install(themeId, repo.bool("theme_dark", false));
            boot("【3/4】构建主界面…");
            buildUi(); // 内部会 setContentView(root) 替换诊断屏
            boot("【4/4】启动完成，界面已展示");
            log("欢迎使用音乐整理（安卓版）· 零第三方依赖", "info");
            requestNotificationPermissionOnce();
            Uri uri = repo.treeUri();
            if (uri != null) {
                // 以前这里是「take 一次，抛异常就 clearTreeUri()」——
                // 而 recreate() 之后（换主题、转屏）Activity 的 Intent 不再带授权，
                // takePersistableUriPermission 在不少机型上会抛 SecurityException，
                // 于是目录设置被抹掉，表现为「频繁丢目录 / 又要重新选目录」。
                //
                // 现在改成：先只读系统记录（persistedUriPermissions，
                // 不抛异常）判断授权还在不在；真没了才补一次，补失败也**不清目录**，
                // 只提示用户重新选（设置还在，重选覆盖即可）。
                if (!repo.hasTreeAccess() && !repo.ensureTreeAccess()) {
                    log("目录授权已失效：重新选一次目录即可（不会自动清掉已选目录）", "warning");
                }
                refreshPath();
            }
            // 恢复上次扫描结果：闪退重开后列表还在，不用重扫
            restoreSnapshot();
            // 外部应用用 ACTION_EDIT 调起时，直接开这个文件的标签编辑器
            handleExternalEdit(getIntent());
        } catch (Throwable t) {
            boot("==== 启动失败，请截图发给开发者 ====");
            boot(exceptionToString(t));
            return; // 保留诊断屏，不切换
        }
        checkLastCrash();
        // 启动后静默查一次（每天最多一次，失败只写日志）
        maybeAutoCheckUpdate();
    }

    @Override
    protected void onResume() {
        super.onResume();
        TaskCenter.addObserver(taskObserver);
        updateTaskPanel();
    }

    @Override
    protected void onPause() {
        super.onPause();
        // 只解除 UI 监听，任务本身继续跑（前台服务持有通知）
        TaskCenter.removeObserver(taskObserver);
    }

    /** Android 13+ 通知权限：请求一次，用于后台运行时的进度通知。 */
    private void requestNotificationPermissionOnce() {
        try {
            if (android.os.Build.VERSION.SDK_INT < 33) {
                return;
            }
            if (repo.bool("notif_asked", false)) {
                return;
            }
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                    == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                return;
            }
            repo.setBool("notif_asked", true);
            requestPermissions(
                    new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 43);
        } catch (Throwable ignored) {
        }
    }

    // ------------------------------------------------------------------
    // 系统媒体库扫描（v0.1.42）：需要 READ_MEDIA_AUDIO（13+）/ READ_EXTERNAL_STORAGE
    // ------------------------------------------------------------------

    /** 请求读取媒体库的权限；授权后自动把媒体库面板打开。 */
    public void requestMediaPermission() {
        try {
            requestPermissions(new String[]{com.dsh.musicorganizer.core.MediaStoreScan.permission()},
                    REQ_MEDIA_PERMISSION);
        } catch (Throwable e) {
            toast("无法请求权限：" + e.getMessage());
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions,
                                           int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != REQ_MEDIA_PERMISSION) {
            return;
        }
        if (com.dsh.musicorganizer.core.MediaStoreScan.hasPermission(this)) {
            log("已获得读取媒体库权限", "success");
            MediaStoreDialog.show(this);
        } else {
            log("未获得读取媒体库权限，媒体库扫描不可用", "warning");
            toast("没有权限就看不到系统媒体库里的歌");
        }
    }

    // ------------------------------------------------------------------
    // 全面屏 / 系统栏适配（v0.1.18）
    //
    // 之前主题里直接给状态栏刷 brand_dark、导航栏刷 card_bg，窗口又"让出"系统栏，
    // 于是屏幕最上面和最下面各留一条纯色空带；打孔摄像头更是白白占掉一截。
    // 现在改成：窗口铺满整块屏幕，系统栏透明，各栏背景自己延伸上去，
    // 再用「系统栏高度」给内容补内边距 —— 视觉上顶栏/底栏贴到屏幕边缘，
    // 文字和按钮仍然避开摄像头与导航条。
    // ------------------------------------------------------------------

    private void applyEdgeToEdge() {
        try {
            applyEdgeToEdgeInner();
        } catch (Throwable t) {
            // 个别 ROM（尤其改动过系统栏实现的 MIUI / HyperOS）可能在这几个调用上抛异常。
            // 全面屏只是观感优化，绝不能因为它让应用起不来 —— 失败就退回普通系统栏布局。
            android.util.Log.w("MusicOrganizer", "applyEdgeToEdge failed", t);
        }
    }

    private void applyEdgeToEdgeInner() {
        Window w = getWindow();
        if (Build.VERSION.SDK_INT >= 30) {
            w.setDecorFitsSystemWindows(false);
        } else {
            // Android 11 以下：用 SYSTEM_UI flag 让内容铺到系统栏背后
            w.getDecorView().setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        }
        w.setStatusBarColor(Color.TRANSPARENT);
        w.setNavigationBarColor(Color.TRANSPARENT);
        if (Build.VERSION.SDK_INT >= 29) {
            // Android 10+ 默认会在手势条背后画一层半透明蒙层，底栏会因此显得"发灰发脏"
            w.setNavigationBarContrastEnforced(false);
            w.setStatusBarContrastEnforced(false);
        }
        if (Build.VERSION.SDK_INT >= 28) {
            // 允许内容进入刘海 / 挖孔所在的短边区域；随后用状态栏高度把它让开，
            // 所以摄像头不会压住标题，只是不再浪费那一截空间。
            WindowManager.LayoutParams lp = w.getAttributes();
            lp.layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            w.setAttributes(lp);
        }
    }

    /**
     * 系统栏图标明暗（浅色主题用深色图标）。
     *
     * <p><b>必须在 setContentView 之后调用</b>：{@code Window.getInsetsController()}
     * 内部直接访问 {@code PhoneWindow.mDecor}，而 mDecor 要等第一次 setContentView
     * 装载布局时才创建。在它之前调用会抛
     * {@code NPE: Attempt to invoke ... DecorView.getWindowInsetsController() on a null object reference}
     * （v0.1.20 启动秒退的真因，堆栈指向的就是这一行）。
     * 这里改用 {@code getDecorView().getWindowInsetsController()}，语义相同但先确保 DecorView 存在。
     */
    private void applyBarIconAppearance() {
        try {
            Window w = getWindow();
            View decor = w.getDecorView();
            if (decor == null) {
                return;
            }
            boolean darkIcons = !UiKit.isDark();
            if (Build.VERSION.SDK_INT >= 30) {
                WindowInsetsController c = decor.getWindowInsetsController();
                if (c != null) {
                    int mask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                            | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                    c.setSystemBarsAppearance(darkIcons ? mask : 0, mask);
                }
            } else {
                int vis = decor.getSystemUiVisibility();
                if (Build.VERSION.SDK_INT >= 23) {
                    vis = darkIcons ? (vis | View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR)
                            : (vis & ~View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR);
                }
                if (Build.VERSION.SDK_INT >= 26) {
                    vis = darkIcons ? (vis | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR)
                            : (vis & ~View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR);
                }
                decor.setSystemUiVisibility(vis);
            }
        } catch (Throwable t) {
            // 图标明暗只是观感，任何 ROM 抛异常都只降级为系统默认，不影响可用性
            android.util.Log.w("MusicOrganizer", "applyBarIconAppearance failed", t);
        }
    }

    /**
     * 当前系统栏占位：{上, 下(导航条), 左, 右, 输入法额外高度}，单位像素。
     *
     * <p>全面屏模式下窗口不再为键盘让位（Android 11+ 由应用自己处理），
     * 所以单列一项「输入法额外高度」= 键盘高度 - 导航条高度，
     * 由根布局整体上移，避免输入框被键盘盖住。
     */
    private int[] sysBarInsets(WindowInsets insets) {
        int top;
        int bottom;
        int left;
        int right;
        int imeExtra = 0;
        if (Build.VERSION.SDK_INT >= 30) {
            android.graphics.Insets bars = insets.getInsets(
                    WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
            android.graphics.Insets ime = insets.getInsets(WindowInsets.Type.ime());
            top = bars.top;
            left = bars.left;
            right = bars.right;
            bottom = bars.bottom;
            imeExtra = Math.max(0, ime.bottom - bars.bottom);
        } else {
            top = insets.getSystemWindowInsetTop();
            bottom = insets.getSystemWindowInsetBottom();
            left = insets.getSystemWindowInsetLeft();
            right = insets.getSystemWindowInsetRight();
        }
        return new int[]{top, bottom, left, right, imeExtra};
    }

    /**
     * 把系统栏高度折算成内边距：顶栏背景铺到屏幕最上沿、底栏背景铺到最下沿，
     * 文字内容仍留在安全区内（打孔摄像头、手势条、键盘都不会压住控件）。
     */
    private void applyInsets(final View root, final View header, final View bottomBar,
                             final int headerBaseV, final int bottomBaseV) {
        root.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
            @Override
            public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
                try {
                    int[] in = sysBarInsets(insets);
                    // 只在值变化时才 setPadding：setPadding 会触发 requestLayout，
                    // 而部分 ROM 会因此在同一次布局里重新分发 insets —— 无脑赋值就会
                    // 「设置 → 重新分发 → 再设置」无限递归，直接 StackOverflow 闪退
                    // （v0.1.18 起的真实事故：装上就闪退，日志都来不及写）。
                    setPaddingIfChanged(header, header.getPaddingLeft(), headerBaseV + in[0],
                            header.getPaddingRight(), headerBaseV);
                    setPaddingIfChanged(bottomBar, bottomBar.getPaddingLeft(), bottomBaseV,
                            bottomBar.getPaddingRight(), bottomBaseV + in[1]);
                    // 横屏时左右短边也可能有挖孔，整块界面横向内缩；
                    // 键盘弹出时整块界面上移，输入框不会被盖住
                    setPaddingIfChanged(root, in[2], 0, in[3], in[4]);
                } catch (Throwable ignored) {
                    // 布局期的兜底：宁可内边距不准，也不能让应用挂在这里
                }
                return insets;
            }
        });
        root.requestApplyInsets();
    }

    /** 值没变就不动 padding（避免 insets 分发 ↔ 布局互相触发）。 */
    private static void setPaddingIfChanged(View v, int left, int top, int right, int bottom) {
        if (v.getPaddingLeft() == left && v.getPaddingTop() == top
                && v.getPaddingRight() == right && v.getPaddingBottom() == bottom) {
            return;
        }
        v.setPadding(left, top, right, bottom);
    }

    /** 启动期始终可见的诊断屏：纯代码构建，不依赖任何主题/布局资源。 */
    private void showBootScreen() {
        bootScroll = new ScrollView(this);
        bootScroll.setBackgroundColor(UiKit.cardColor());
        bootText = new TextView(this);
        bootText.setTextColor(UiKit.textColor());
        bootText.setTypeface(Typeface.MONOSPACE);
        bootText.setTextSize(14);
        int pad = (int) (16 * getResources().getDisplayMetrics().density);
        bootText.setPadding(pad, pad, pad, pad);
        bootText.setText("应用启动中…\n");
        bootScroll.addView(bootText);
        setContentView(bootScroll);
        // 有了 DecorView 才能设系统栏图标明暗（在 setContentView 之前调用会空指针，见方法注释）
        applyBarIconAppearance();
        // 诊断屏同样让开系统栏：否则标题被状态栏 / 打孔摄像头压住
        bootScroll.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
            @Override
            public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
                try {
                    int[] in = sysBarInsets(insets);
                    // 同样只在变化时写 padding，否则会陷入「设置 → 重新分发」的死循环
                    setPaddingIfChanged(v, in[2], in[0], in[3], in[1] + in[4]);
                } catch (Throwable ignored) {
                }
                return insets;
            }
        });
    }

    private void boot(String line) {
        if (bootText != null) {
            bootText.append(line + "\n");
            final ScrollView sv = bootScroll;
            if (sv != null) {
                sv.post(new Runnable() {
                    @Override
                    public void run() {
                        sv.fullScroll(ScrollView.FOCUS_DOWN);
                    }
                });
            }
        }
    }

    private static String exceptionToString(Throwable t) {
        StringBuilder sb = new StringBuilder();
        sb.append("设备: ").append(android.os.Build.MANUFACTURER).append(" ")
          .append(android.os.Build.MODEL).append("  Android ")
          .append(android.os.Build.VERSION.RELEASE).append("\n");
        sb.append("类型: ").append(t.getClass().getName()).append("\n");
        sb.append("信息: ").append(String.valueOf(t.getMessage())).append("\n\n");
        java.io.StringWriter sw = new java.io.StringWriter();
        t.printStackTrace(new java.io.PrintWriter(sw));
        sb.append(sw.toString());
        return sb.toString();
    }

    /**
     * 若上次运行曾发生未被同步 try-catch 捕获的崩溃，这里把留痕显示出来，
     * 并允许用户一键复制，然后删除文件，避免重复打扰。
     */
    private void checkLastCrash() {
        try {
            File f = new File(getFilesDir(), "last_crash.txt");
            if (!f.exists()) {
                return;
            }
            StringBuilder sb = new StringBuilder();
            BufferedReader br = new BufferedReader(new FileReader(f));
            String line;
            while ((line = br.readLine()) != null) {
                sb.append(line).append("\n");
            }
            br.close();
            f.delete();
            final String text = sb.toString();
            new UiKit.Builder(this)
                    .setTitle("检测到上次崩溃记录")
                    .setMessage(text.length() > 4000
                            ? text.substring(0, 4000) + "\n...(已截断)"
                            : text)
                    .setPositiveButton("复制并关闭",
                            new android.content.DialogInterface.OnClickListener() {
                                @Override
                                public void onClick(android.content.DialogInterface d, int w) {
                                    try {
                                        android.content.ClipboardManager cm =
                                                (android.content.ClipboardManager)
                                                        getSystemService(CLIPBOARD_SERVICE);
                                        cm.setPrimaryClip(
                                                android.content.ClipData.newPlainText("crash", text));
                                        Toast.makeText(MainActivity.this,
                                                "已复制到剪贴板", Toast.LENGTH_SHORT).show();
                                    } catch (Throwable ignore) {
                                    }
                                }
                            })
                    .show();
        } catch (Throwable ignore) {
        }
    }

    // ------------------------------------------------------------------
    // UI 构建
    // ------------------------------------------------------------------

    /** 上一次扫描（或恢复快照）的时间戳；文件页搜不到东西时要靠它说清「列表有多旧」。 */

    /**
     * 读系统里真实的版本号（来自 AndroidManifest 的 versionName）。
     * 以前这里写死成 "v2.4"，每升一版都忘了改，界面上显示的版本就和 APK 文件名对不上；
     * 改成从 PackageManager 读，永远跟构建产物一致，不需要维护。
     */
    public String versionName() {
        try {
            return getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "?";
        }
    }

    /** 构建号（versionCode）。升级判定不靠它，但装了什么包一眼能看出来。 */
    public int versionCode() {
        try {
            android.content.pm.PackageInfo pi =
                    getPackageManager().getPackageInfo(getPackageName(), 0);
            if (android.os.Build.VERSION.SDK_INT >= 28) {
                return (int) pi.getLongVersionCode();
            }
            return pi.versionCode;
        } catch (Exception e) {
            return 0;
        }
    }

    private void buildUi() {
        LinearLayout root = UiKit.vertical(this);
        root.setBackgroundColor(UiKit.bgColor());

        // 顶栏（三槽：左 / 中 / 右），内容由 renderHeader() 按当前页决定
        FrameLayout header = new FrameLayout(this);
        final int headerPadV = UiKit.dp(this, 14);
        header.setPadding(UiKit.dp(this, 12), headerPadV, UiKit.dp(this, 12), headerPadV);
        header.setBackgroundColor(UiKit.cardColor());

        headerSlotLeft = UiKit.horizontal(this);
        headerSlotLeft.setGravity(Gravity.CENTER_VERTICAL);
        FrameLayout.LayoutParams leftLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.MATCH_PARENT);
        leftLp.gravity = Gravity.START | Gravity.CENTER_VERTICAL;
        header.addView(headerSlotLeft, leftLp);

        headerSlotCenter = UiKit.horizontal(this);
        headerSlotCenter.setGravity(Gravity.CENTER);
        FrameLayout.LayoutParams centerLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.MATCH_PARENT);
        centerLp.gravity = Gravity.CENTER;
        header.addView(headerSlotCenter, centerLp);

        headerSlotRight = UiKit.horizontal(this);
        headerSlotRight.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
        FrameLayout.LayoutParams rightLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.MATCH_PARENT);
        rightLp.gravity = Gravity.END | Gravity.CENTER_VERTICAL;
        header.addView(headerSlotRight, rightLp);

        root.addView(header);
        // 先按当前页填一次；buildUi 末尾的 switchTab(savedTab) 会再按恢复的页重建
        renderHeader();

        // 内容区
        content = new FrameLayout(this);
        content.setLayoutParams(new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));
        organizePage = new OrganizePage(this);
        browsePage = new BrowsePage(this);
        settingsPage = new SettingsPage(this);
        buildLogPage();
        content.addView(organizePage);
        content.addView(browsePage);
        browsePage.setVisibility(View.GONE);
        content.addView(logPage);
        logPage.setVisibility(View.GONE);
        content.addView(settingsPage);
        settingsPage.setVisibility(View.GONE);
        root.addView(content);

        // 单主界面：不再有底部多标签，主界面就是上面的「音乐库」内容区。
        // 整理 / 日志 / 设置统一从右上角齿轮进入的设置页打开（见 SettingsPage「工具」卡）。

        // 状态栏（任务面板）：高度**恒定**，任务开始/结束时不会整块上下跳。
        // 做法：三个操作按钮用 INVISIBLE 而不是 GONE —— GONE 会让行高变化，
        // 底栏一变，上面的列表就跟着重排，看起来就是「下方抖动」。
        LinearLayout status = UiKit.vertical(this);
        final int statusPadV = UiKit.dp(this, 6);
        status.setPadding(UiKit.dp(this, 16), statusPadV, UiKit.dp(this, 16), statusPadV);
        status.setBackgroundColor(UiKit.cardColor());
        progressBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progressBar.setMax(100);
        progressBar.setProgress(0);
        progressBar.setLayoutParams(new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, UiKit.dp(this, 3)));

        statusText = UiKit.caption(this, "就绪");
        statusText.setSingleLine(true);
        statusText.setEllipsize(android.text.TextUtils.TruncateAt.END);
        LinearLayout statusRow = UiKit.horizontal(this);
        statusRow.setGravity(Gravity.CENTER_VERTICAL);
        statusText.setLayoutParams(new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        statusRow.addView(statusText);

        btnTaskPreview = UiKit.chip(this, "预览", false);
        btnTaskPause = UiKit.chip(this, "暂停", false);
        btnTaskStop = UiKit.chip(this, "停止", false);
        TextView[] actions = {btnTaskPreview, btnTaskPause, btnTaskStop};
        for (TextView b : actions) {
            b.setVisibility(View.INVISIBLE);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            lp.setMargins(UiKit.dp(this, 6), 0, 0, 0);
            statusRow.addView(b, lp);
        }
        btnTaskPause.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                TaskControl c = TaskCenter.current();
                if (c != null) {
                    c.togglePause();
                    PartialPreview p = TaskCenter.partial();
                    int n = p == null ? 0 : p.count();
                    if (!c.isPaused()) {
                        toast("继续执行");
                    } else if (n > 0) {
                        toast("已暂停，可点「预览 " + n + "」");
                    } else {
                        toast("已暂停（可后台运行）");
                    }
                    updateTaskPanel();
                }
            }
        });
        btnTaskStop.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                TaskControl c = TaskCenter.current();
                if (c != null) {
                    c.cancel();
                    toast("正在停止…");
                    updateTaskPanel();
                }
            }
        });
        btnTaskPreview.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                PartialPreview p = TaskCenter.partial();
                if (p == null) {
                    toast("当前任务不支持预览已获取部分");
                    return;
                }
                if (p.count() <= 0) {
                    toast("还没有已获取的结果，再等一会儿或直接停止");
                    return;
                }
                p.show(MainActivity.this);
            }
        });

        status.addView(progressBar);
        status.addView(statusRow);
        root.addView(status);

        setContentView(root);
        // 正式界面换上来后再设一次（诊断屏那次可能已被主题/重建覆盖）
        applyBarIconAppearance();
        // 全面屏收尾：顶栏贴到屏幕最上沿（让开状态栏/挖孔），底栏贴到最下沿（让开导航条/键盘）
        applyInsets(root, header, status, headerPadV, statusPadV);
        // 恢复重建前的页（换主题会 recreate），首次启动默认主界面「音乐库」
        int savedTab = repo.intVal(KEY_LAST_TAB, 1);
        switchTab(savedTab);
        // 首次安装 / 还没有目录：自动弹一次系统目录授权。授权后 onActivityResult 会自动扫描，
        // 扫描完成自动显示文件列表（整条链路见 pickFolder → onActivityResult → scanGroups.done）。
        if (repo.treeUri() == null && !repo.bool("auto_pick_prompted", false)) {
            repo.setBool("auto_pick_prompted", true);
            root.post(new Runnable() {
                @Override
                public void run() {
                    pickFolder();
                }
            });
        }
    }

    /**
     * 按当前页重建顶栏：
     *
     * <ul>
     *   <li><b>主界面（音乐库）</b>：左＝设置齿轮，中＝「♪ 音乐库」胶囊，右＝排序入口；</li>
     *   <li><b>子页（整理 / 日志 / 设置）</b>：左＝返回主界面的箭头，中＝页名，右侧留空，
     *       不再显示齿轮与音乐库图标。</li>
     * </ul>
     */
    private void renderHeader() {
        if (headerSlotLeft == null || headerSlotCenter == null || headerSlotRight == null) {
            return;
        }
        headerSlotLeft.removeAllViews();
        headerSlotCenter.removeAllViews();
        headerSlotRight.removeAllViews();

        if (currentTab == 1) {
            headerSlotLeft.addView(headerIcon(NavIcon.GEAR, "设置", new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    switchTab(3);
                }
            }));
            headerSlotCenter.addView(buildBrandPill());
            headerSlotRight.addView(headerIcon(NavIcon.SORT, "排序", new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    if (browsePage != null) {
                        browsePage.showSortDialog();
                    }
                }
            }));
            return;
        }

        headerSlotLeft.addView(headerIcon(NavIcon.BACK, "返回主界面", new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                switchTab(1);
            }
        }));
        String title;
        if (currentTab == 3) {
            title = "设置";
        } else if (currentTab == 0) {
            title = "整理";
        } else {
            title = "日志";
        }
        TextView titleView = UiKit.text(this, title, 17, UiKit.textColor(), true);
        titleView.setGravity(Gravity.CENTER);
        headerSlotCenter.addView(titleView);
    }

    /** 顶栏图标按钮：44dp 触摸区里画 22dp 线性图标（和原来齿轮的手感一致）。 */
    private ImageView headerIcon(int kind, String desc, View.OnClickListener onClick) {
        ImageView icon = new ImageView(this);
        icon.setImageDrawable(new NavIcon(kind, UiKit.bodyColor()));
        icon.setScaleType(ImageView.ScaleType.FIT_CENTER);
        int pad = UiKit.dp(this, 11);
        icon.setPadding(pad, pad, pad, pad);
        icon.setContentDescription(desc);
        icon.setOnClickListener(onClick);
        applyRipple(icon);
        icon.setLayoutParams(new LinearLayout.LayoutParams(
                UiKit.dp(this, 44), UiKit.dp(this, 44)));
        return icon;
    }

    /** 主界面的「♪ 音乐库」胶囊（只在主界面显示，设置页不再出现）。 */
    private View buildBrandPill() {
        LinearLayout brand = UiKit.horizontal(this);
        brand.setGravity(Gravity.CENTER_VERTICAL);
        GradientDrawable brandBg = new GradientDrawable();
        brandBg.setColor(UiKit.primarySoft());
        brandBg.setCornerRadius(UiKit.dp(this, 999));
        brand.setBackground(brandBg);
        int brandPadH = UiKit.dp(this, 14);
        int brandPadV = UiKit.dp(this, 8);
        brand.setPadding(brandPadH, brandPadV, brandPadH, brandPadV);
        brand.addView(UiKit.text(this, "♪", 16, UiKit.primary(), true));
        TextView brandName = UiKit.text(this, "音乐库", 15, UiKit.primary(), true);
        UiKit.margin(brandName, 6, 0, 0, 0);
        brand.addView(brandName);
        return brand;
    }

    private void buildLogPage() {
        logPage = UiKit.vertical(this);
        int pad = UiKit.dp(this, 12);
        logPage.setPadding(pad, pad, pad, pad);
        LinearLayout row = UiKit.horizontal(this);
        TextView cap = UiKit.text(this, "运行日志", 15, UiKit.textColor(), true);
        cap.setLayoutParams(new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        row.addView(cap);
        Button export = UiKit.button(this, "导出", false);
        export.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                exportLogs();
            }
        });
        row.addView(export);
        Button clear = UiKit.button(this, "清空", false);
        clear.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                synchronized (repo.logLines) {
                    repo.logLines.clear();
                }
                // 同时丢弃还没刷进列表的排队日志，否则清空后它们会立刻冒出来
                synchronized (pendingLogs) {
                    pendingLogs.clear();
                }
                logAdapter.notifyDataSetChanged();
                // 已落盘的文件也一起清，否则「导出」又把旧日志带回来
                int n = AppLog.clearFiles();
                refreshLogStats();
                toast(n > 0 ? "已清空（含 " + n + " 个日志文件）" : "已清空");
            }
        });
        row.addView(clear);
        logPage.addView(row);
        logStatsText = UiKit.caption(this, logStatsText());
        UiKit.margin(logStatsText, 0, 4, 0, 0);
        logPage.addView(logStatsText);
        logAdapter = new LogAdapter();
        logList = new android.widget.ListView(this);
        logList.setAdapter(logAdapter);
        logList.setDivider(null);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f);
        lp.setMargins(0, UiKit.dp(this, 8), 0, 0);
        logList.setLayoutParams(lp);
        logPage.addView(logList);
    }

    /** 批量任务记忆（{@code filesDir/batches/<kind>.json}）：标签用 tags，歌词用 lyrics。 */
    public BatchMemory batchMemory(String kind) {
        BatchMemory m = BatchMemory.open(new File(getFilesDir(), "batches"), kind);
        // 设置页的「忽略匹配记忆」：这一轮全部重新联网查询，新结论照常记回去。
        // 这是「前面跳过的歌现在想重查」的全局入口，库页/整理页的所有批量都吃这个开关。
        m.setIgnoreExisting(repo.bool("ignore_memory", false));
        return m;
    }

    /**
     * 批量匹配的中间态队列（断点续跑）。
     *
     * <p>与 {@link #batchMemory} 同目录、不同文件：记忆记「已经查过什么」，
     * 队列记「查到但还没写什么」，两件事不能混在一份文件里。
     */
    public com.dsh.musicorganizer.core.MatchQueue batchQueue(String kind) {
        return com.dsh.musicorganizer.core.MatchQueue.open(new File(getFilesDir(), "batches"), kind);
    }

    private String logStatsText() {
        return "已落盘 " + AppLog.stats() + "（保留 " + AppLog.KEEP_DAYS
                + " 天，崩溃堆栈也会记进去；「导出」可发给开发者）";
    }

    private void refreshLogStats() {
        if (logStatsText != null) {
            logStatsText.setText(logStatsText());
        }
    }

    /**
     * 切页。index：0 整理 / 1 库 / 2 日志 / 3 设置（设置从右上角齿轮进，底部导航不占位）。
     *
     * <p>索引写进偏好：切换主题会 recreate 整个 Activity，靠它回到原来的页。
     */
    private void switchTab(int index) {
        if (index < 0 || index > 3) {
            index = 1; // 默认主界面 = 音乐库
        }
        currentTab = index;
        organizePage.setVisibility(index == 0 ? View.VISIBLE : View.GONE);
        browsePage.setVisibility(index == 1 ? View.VISIBLE : View.GONE);
        logPage.setVisibility(index == 2 ? View.VISIBLE : View.GONE);
        settingsPage.setVisibility(index == 3 ? View.VISIBLE : View.GONE);
        if (index == 2) {
            logAdapter.notifyDataSetChanged();
        }
        if (index == 3) {
            // 进设置页时刷新更新状态行（检查结果/停用提示可能已变化）
            settingsPage.refreshUpdateStatus();
        }
        if (repo != null) {
            repo.setInt(KEY_LAST_TAB, index);
        }
        // 顶栏随页切换：主界面＝齿轮/音乐库/排序，子页＝返回箭头/页名
        renderHeader();
    }

    /** 任何子页（整理 / 日志 / 设置）按返回都回到主界面「音乐库」，再按才退出。 */
    @Override
    public void onBackPressed() {
        if (currentTab != 1) {
            switchTab(1);
            return;
        }
        super.onBackPressed();
    }

    /** 给图标按钮加系统水波纹（老系统拿不到资源就静默跳过）。 */
    private void applyRipple(View v) {
        try {
            android.util.TypedValue out = new android.util.TypedValue();
            if (getTheme().resolveAttribute(
                    android.R.attr.selectableItemBackgroundBorderless, out, true)) {
                v.setBackgroundResource(out.resourceId);
            }
        } catch (Throwable ignored) {
        }
    }



    // ------------------------------------------------------------------
    // 目录选择
    // ------------------------------------------------------------------

    /** 打开系统目录选择器（设置页「音乐库目录」与首次安装自动授权都走这里）。 */
    public void pickFolder() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
        startActivityForResult(intent, REQ_PICK_TREE);
    }

    /** 移除当前音乐库目录：只清授权与列表缓存，不删除任何文件。 */
    public void clearFolder() {
        repo.clearTreeUri();
        com.dsh.musicorganizer.core.ScanSnapshot.clear(scanDir());
        repo.lastGroups.clear();
        repo.lastFiles.clear();
        if (browsePage != null) {
            browsePage.reload();
        }
        switchTab(1);
        toast("已移除音乐库文件夹");
    }

    /** 移除某一个目录（多根，v0.1.91）。 */
    public void removeFolder(Uri uri) {
        repo.removeRoot(uri);
        repo.lastGroups.clear();
        repo.lastFiles.clear();
        if (browsePage != null) {
            browsePage.reload();
        }
        refreshPath();
        toast("已移除该目录");
    }

    /** 设置整理目标目录（移动/归位的落点）。 */
    public void setOrganizeFolder(Uri uri) {
        repo.setOrganizeRoot(uri);
        refreshPath();
        toast("整理目标已更新");
    }

    /** 两个 SAF 目录是否指向同一棵树（比较 tree docId + authority，避免 URI 编码差异误判）。 */
    private static boolean sameTree(Uri a, Uri b) {
        if (a == null || b == null) {
            return false;
        }
        try {
            String ia = DocumentsContract.getTreeDocumentId(a);
            String ib = DocumentsContract.getTreeDocumentId(b);
            if (ia != null && ib != null) {
                String aa = a.getAuthority();
                String ab = b.getAuthority();
                return ia.equals(ib) && aa != null && aa.equals(ab);
            }
        } catch (Throwable ignored) {
        }
        return a.toString().equals(b.toString());
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == TagEditorDialog.REQ_PICK_COVER) {
            TagEditorDialog.handlePickResult(this, resultCode, data);
            return;
        }
        boolean isFileOp = requestCode == REQ_EXPORT_LOG
                || requestCode == REQ_EXPORT_SETTINGS
                || requestCode == REQ_IMPORT_SETTINGS
                || requestCode == REQ_EXPORT_CSV;
        if (resultCode != RESULT_OK || data == null || data.getData() == null) {
            if (isFileOp) {
                pendingExportText = null;
                pendingExportName = null;
                if (resultCode == RESULT_OK) {
                    toast("没有选择文件，已取消");
                }
            }
            return;
        }
        Uri uri = data.getData();
        if (requestCode == REQ_PICK_TREE) {
            // 已经在音乐库里（含多根）：不重扫、不清空，保留现有列表（含已读标签/封面）。
            boolean already = false;
            for (Uri r : repo.roots()) {
                if (sameTree(r, uri)) {
                    already = true;
                    break;
                }
            }
            if (already) {
                toast("目录已在音乐库里，继续使用当前列表");
                return;
            }
            try {
                getContentResolver().takePersistableUriPermission(uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                                | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            } catch (Exception ignored) {
            }
            repo.addRoot(uri);   // v0.1.91：多根追加，而不是替换
            repo.storage = null;
            // 换了目录：旧快照属于另一个目录树，留着只会让人以为文件还在
            com.dsh.musicorganizer.core.ScanSnapshot.clear(scanDir());
            refreshPath();
            // 授权后：丢掉旧列表 → 切到音乐库 → 立即扫描；扫完在 done() 里自动显示列表
            repo.lastGroups.clear();
            repo.lastFiles.clear();
            if (browsePage != null) {
                browsePage.reload();
            }
            switchTab(1);
            toast("目录已选择：" + repo.treeDisplayName() + "，正在扫描…");
            scanGroups(false);
            return;
        }
        if (requestCode == REQ_EXPORT_LOG || requestCode == REQ_EXPORT_SETTINGS
                || requestCode == REQ_EXPORT_CSV) {
            writeExport(uri);
            return;
        }
        if (requestCode == REQ_IMPORT_SETTINGS) {
            applyImport(uri);
        }
    }

    private void refreshPath() {
        // 顶栏已不再显示目录（v0.1.68），保留空实现避免调用点 NPE
        if (pathText != null) {
            pathText.setText(repo.treeDisplayName());
        }
    }

    // ------------------------------------------------------------------
    // 导出 / 导入（运行日志、设置备份）
    // ------------------------------------------------------------------

    private static String stampForFile() {
        return new java.text.SimpleDateFormat("yyyyMMdd-HHmm", java.util.Locale.US)
                .format(new java.util.Date());
    }

    private static String stampForHuman() {
        return new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", java.util.Locale.US)
                .format(new java.util.Date());
    }

    /** 导出运行日志：正文在点「保存」前就生成好，SAF 返回后直接写。 */
    public void exportLogs() {
        StringBuilder header = new StringBuilder();
        header.append("音乐整理 v").append(versionName()).append('\n');
        header.append("设备: ").append(android.os.Build.MANUFACTURER).append(' ')
                .append(android.os.Build.MODEL).append("  Android ")
                .append(android.os.Build.VERSION.RELEASE).append('\n');
        header.append("导出时间: ").append(stampForHuman()).append('\n');
        header.append("音乐目录: ").append(repo.treeDisplayName()).append('\n');
        header.append("在线日志条数: ").append(repo.snapshotLogs().size()).append('\n');
        String text = AppLog.exportText(header.toString(), AppLog.EXPORT_MAX_CHARS);
        startExport("音乐整理-日志-" + stampForFile() + ".txt", text, REQ_EXPORT_LOG);
    }

    /** 导出设置备份（JSON）。 */
    public void exportSettings() {
        Map<String, Object> values = repo.exportSettings();
        String json = SettingsBackup.toJson(values, stampForHuman());
        startExport("音乐整理-设置-" + stampForFile() + ".json", json, REQ_EXPORT_SETTINGS);
        log("已生成设置备份：" + values.size() + " 项，选择保存位置即可", "info");
    }

    /**
     * 导出曲库清单（CSV）—— 标签在后台读，读完再弹保存位置。
     *
     * <p>为什么不是点了就弹保存框：几百首的标签要读好几秒，先选文件再干等会让人以为卡住。
     */
    public void exportLibraryCsv() {
        final java.util.List<com.dsh.musicorganizer.core.VFile> audio =
                com.dsh.musicorganizer.core.CsvExport.audioOnly(repo.lastFiles);
        if (audio.isEmpty()) {
            toast("还没有扫描到音频文件，先去整理页「自动整理」");
            return;
        }
        runTask("导出曲库清单", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                com.dsh.musicorganizer.core.Storage st = safeStorage();
                java.util.Set<String> lrcBases = new java.util.HashSet<String>();
                for (com.dsh.musicorganizer.core.VFile f : repo.lastFiles) {
                    if (f.lyric()) {
                        lrcBases.add(f.stem().trim().toLowerCase(java.util.Locale.US));
                    }
                }
                java.util.List<com.dsh.musicorganizer.core.CsvExport.Row> rows =
                        new java.util.ArrayList<com.dsh.musicorganizer.core.CsvExport.Row>();
                for (com.dsh.musicorganizer.core.VFile f : audio) {
                    if (cancelToken().isCancelled()) {
                        break;
                    }
                    com.dsh.musicorganizer.core.Tags tags =
                            com.dsh.musicorganizer.core.Scanner.readTagsCheap(st,
                                    getContentResolver(), f);
                    boolean lyrics = lrcBases.contains(
                            f.stem().trim().toLowerCase(java.util.Locale.US))
                            || !tags.get(com.dsh.musicorganizer.core.Tags.LYRICS).trim().isEmpty();
                    boolean cover = com.dsh.musicorganizer.core.Scanner.hasCover(st,
                            getContentResolver(), f);
                    com.dsh.musicorganizer.core.CsvExport.Row row =
                            com.dsh.musicorganizer.core.CsvExport.make(f, tags, cover, lyrics);
                    row.dir = f.parentId == null ? "" : f.parentId;
                    rows.add(row);
                }
                return com.dsh.musicorganizer.core.CsvExport.build(rows);
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    fail(error);
                    return;
                }
                String csv = (String) result;
                int rows = com.dsh.musicorganizer.core.CsvExport.rowCount(csv);
                startExport(com.dsh.musicorganizer.core.CsvExport.defaultFileName(
                        new java.util.Date()), csv, REQ_EXPORT_CSV);
                log("已生成曲库清单：" + rows + " 行，选择保存位置即可", "info");
            }
        });
    }

    /** 打开系统媒体库面板（v0.1.42）：SAF 选不到的目录（如「下载」）靠它列出来。 */
    public void openMediaLibrary() {
        if (repo.treeUri() == null) {
            toast("先在整理页选一个音乐目录，导入要有个落脚点");
            return;
        }
        MediaStoreDialog.show(this);
    }

    /** 选择要导入的设置备份文件。 */
    public void importSettings() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        try {
            startActivityForResult(intent, REQ_IMPORT_SETTINGS);
        } catch (Exception e) {
            toast("没有可用的文件选择器");
        }
    }

    private void startExport(String name, String text, int requestCode) {
        pendingExportName = name;
        pendingExportText = text;
        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("text/plain");
        intent.putExtra(Intent.EXTRA_TITLE, name);
        try {
            startActivityForResult(intent, requestCode);
        } catch (Exception e) {
            pendingExportText = null;
            pendingExportName = null;
            toast("没有可用的文件选择器");
        }
    }

    private void writeExport(Uri uri) {
        String text = pendingExportText;
        String name = pendingExportName;
        pendingExportText = null;
        pendingExportName = null;
        if (text == null) {
            return;
        }
        try {
            java.io.OutputStream os = getContentResolver().openOutputStream(uri, "wt");
            if (os == null) {
                throw new java.io.IOException("无法写入所选位置");
            }
            try {
                os.write(text.getBytes("UTF-8"));
                os.flush();
            } finally {
                os.close();
            }
            toast("已导出：" + (name == null ? "" : name));
            log("已导出 " + (name == null ? "文件" : name)
                    + "（" + AppLog.humanSize(text.getBytes("UTF-8").length) + "）", "success");
            refreshLogStats();
        } catch (Exception e) {
            log("导出失败：" + TextUtil.shortError(e), "error");
            message("导出失败", TextUtil.shortError(e));
        }
    }

    private void applyImport(Uri uri) {
        String text;
        try {
            java.io.InputStream in = getContentResolver().openInputStream(uri);
            if (in == null) {
                throw new java.io.IOException("无法读取所选文件");
            }
            java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
            try {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) {
                    bos.write(buf, 0, n);
                    if (bos.size() > 2 * 1024 * 1024) {
                        throw new java.io.IOException("文件太大，不像是设置备份");
                    }
                }
            } finally {
                in.close();
            }
            text = new String(bos.toByteArray(), "UTF-8");
        } catch (Exception e) {
            message("读取失败", TextUtil.shortError(e));
            return;
        }
        final SettingsBackup.Import parsed = SettingsBackup.fromJson(text);
        if (!parsed.ok) {
            message("无法导入", parsed.summary());
            return;
        }
        if (parsed.count() == 0) {
            message("没有可导入的设置", parsed.summary());
            return;
        }
        confirm("导入设置",
                parsed.summary() + "\n\n将覆盖同名的现有设置（文件里没有的项保持不变）。继续？",
                new Runnable() {
                    @Override
                    public void run() {
                        int n = repo.importSettings(parsed.values);
                        log("设置已导入：" + n + " 项（" + parsed.summary().replace("\n", " ")
                                + "）", "success");
                        toast("已导入 " + n + " 项设置");
                        if (TaskCenter.busy()) {
                            message("导入完成",
                                    "已写入 " + n + " 项。当前有任务在跑，界面上的开关会在任务结束后生效；"
                                            + "也可以稍后重启应用。");
                            return;
                        }
                        // 界面是按偏好构建的，重建一次让所有开关/滑块反映新值
                        recreate();
                    }
                });
    }

    // ------------------------------------------------------------------
    // 任务基础设施
    // ------------------------------------------------------------------

    public Storage safeStorage() throws Exception {
        return repo.openStorage();
    }

    // ------------------------------------------------------------------
    // 外部编辑协议（ACTION_EDIT）
    // ------------------------------------------------------------------

    /**
     * 处理别的应用发来的「编辑这个音频的标签」请求。
     *
     * <p>为什么只做「映射到已授权目录」而不是直接拿 URI 写：标签写入走的是
     * SAF 目录树（{@link Storage} + {@code TagTransaction} 的事务/自检/回滚全建立在这套路径上），
     * 拿一个来路不明的 document URI 直接写会把「写坏能自检」这条保证绕过去。
     * 所以这里先把它翻译成库里的 docId，能对上就正常走编辑器；对不上就明确告诉用户
     * 该把哪个目录加进来 —— 比悄悄失败有用。
     */
    private void handleExternalEdit(android.content.Intent intent) {
        if (intent == null || !android.content.Intent.ACTION_EDIT.equals(intent.getAction())) {
            return;
        }
        android.net.Uri uri = intent.getData();
        if (uri == null) {
            uri = intent.getParcelableExtra(android.content.Intent.EXTRA_STREAM);
        }
        if (uri == null) {
            toast("没有收到文件");
            return;
        }
        String docId = docIdOf(uri);
        if (docId == null) {
            message("无法定位这个文件",
                    "只支持「文件」类地址（content://…documents/… 或系统媒体库）。\n"
                            + "如果是从网盘 / 压缩包里打开的，请先保存到本机音乐文件夹。");
            return;
        }
        try {
            Storage st = safeStorage();
            String parent = docId.lastIndexOf('/') > 0
                    ? docId.substring(0, docId.lastIndexOf('/')) : null;
            VFile f = st.stat(docId, parent);
            if (f == null || f.dir) {
                message("这个文件不在音乐库里",
                        "先把它所在的文件夹加入音乐库：设置 → 文件夹管理 → 添加文件夹。\n"
                                + "加好之后从文件管理器再点一次「用其它应用编辑」即可。");
                return;
            }
            if (!f.audio()) {
                toast("这不是音频文件：" + f.name);
                return;
            }
            if (!com.dsh.musicorganizer.core.TagIO.canWrite(f.ext())) {
                message("这种格式只能读",
                        f.name + " 的标签写入还不支持（WMA 等格式只读）。");
                return;
            }
            log("外部调起编辑：" + f.name, "info");
            TagEditorDialog.show(this, f);
        } catch (Exception e) {
            message("打不开这个文件", TextUtil.shortError(e)
                    + "\n\n确认该文件所在文件夹已在「设置 → 文件夹管理」里授权。");
        }
    }

    /** 把外部 URI 翻成 SAF docId（documents URI 直接取，媒体库 / file 走路径换算）。 */
    private String docIdOf(android.net.Uri uri) {
        try {
            String id = android.provider.DocumentsContract.getDocumentId(uri);
            if (id != null && !id.isEmpty()) {
                return id;
            }
        } catch (Exception ignored) {
        }
        String path = null;
        try {
            if ("file".equals(uri.getScheme())) {
                path = uri.getPath();
            } else {
                android.database.Cursor c = getContentResolver().query(uri,
                        new String[]{"_data"}, null, null, null);
                if (c != null) {
                    try {
                        if (c.moveToFirst()) {
                            path = c.getString(0);
                        }
                    } finally {
                        c.close();
                    }
                }
            }
        } catch (Exception ignored) {
        }
        if (path == null) {
            return null;
        }
        String root = android.os.Environment.getExternalStorageDirectory().getAbsolutePath();
        if (path.startsWith(root + "/")) {
            return "primary:" + path.substring(root.length() + 1);
        }
        return null;
    }

    @Override
    protected void onNewIntent(android.content.Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleExternalEdit(intent);
    }

    public VFile root() throws Exception {
        return repo.openStorage().root();
    }

    /** 遍历全部已授权目录，按歌手归组（v0.1.91）：整理据此把各目录的歌归位到整理目标。 */
    private List<TrackGroup> scanGroupsAll(boolean recursive, boolean skipArtist,
                                           Scanner.Stats stats) throws Exception {
        List<TrackGroup> out = new ArrayList<TrackGroup>();
        for (Uri uri : repo.roots()) {
            if (cancelToken().isCancelled()) {
                break;
            }
            Storage st = repo.openStorage(uri);
            Scanner.Stats part = new Scanner.Stats();
            out.addAll(Scanner.scanGroups(st, st.root(), recursive, skipArtist, false,
                    getContentResolver(), part, progressCallback(), cancelToken()));
            stats.audio += part.audio;
            stats.lyrics += part.lyrics;
            stats.files += part.files;
            stats.groups += part.groups;
            stats.skippedArtist += part.skippedArtist;
            stats.skippedUnrecognized += part.skippedUnrecognized;
            stats.ignored += part.ignored;
        }
        return out;
    }

    /** 遍历全部已授权目录合并成一个列表（v0.1.91）：浏览/查重/歌词/标签用；整理仍走 root()。 */
    public List<VFile> scanMusicAll(boolean recursive, com.dsh.musicorganizer.core.Progress progress,
                                    com.dsh.musicorganizer.core.CancelToken cancel,
                                    int[] dupOut) throws Exception {
        List<VFile> out = new ArrayList<VFile>();
        java.util.Set<String> seen = new java.util.HashSet<String>();
        for (Uri uri : repo.roots()) {
            if (cancel != null && cancel.isCancelled()) {
                break;
            }
            Storage st = repo.openStorage(uri);
            int[] localDup = new int[]{0};
            List<VFile> part = Scanner.walkMusic(st, st.root(), recursive, progress, cancel,
                    localDup);
            for (VFile f : part) {
                if (seen.add(f.docId)) {
                    out.add(f);
                }
            }
            if (dupOut != null && dupOut.length > 0) {
                dupOut[0] += localDup[0];
            }
        }
        return out;
    }

    public Progress progressCallback() {
        return new Progress() {
            @Override
            public void onProgress(int done, int total, String message) {
                TaskControl c = TaskCenter.current();
                if (c != null) {
                    c.report(done, total, message); // 内部会切主线程刷新面板与通知栏
                }
            }
        };
    }

    public CancelToken cancelToken() {
        TaskControl c = TaskCenter.current();
        return c != null ? c : IDLE_TOKEN;
    }

    /** 上一次任务是否被用户「停止」终止（用于避免拿半截结果去做危险操作）。 */
    public boolean lastTaskStopped() {
        return lastTaskStopped;
    }

    /**
     * 底部任务面板：只在任务运行时显示进度与操作。
     *
     * <p>所有显隐都用 {@code INVISIBLE}（占位不显示）而不是 {@code GONE}（不占位）：
     * 这个面板在屏幕最下方，行高一变，上面的列表就会整体重排，
     * 长任务一多（尤其按需读标签那种一批一批的短任务）看起来就在抖。
     */
    private void updateTaskPanel() {
        if (btnTaskPause == null || btnTaskStop == null || statusText == null) {
            return;
        }
        boolean running = TaskCenter.busy();
        if (!running) {
            btnTaskPause.setVisibility(View.INVISIBLE);
            btnTaskStop.setVisibility(View.INVISIBLE);
            if (btnTaskPreview != null) {
                btnTaskPreview.setVisibility(View.INVISIBLE);
            }
            progressBar.setProgress(0);
            statusText.setText("就绪");
            return;
        }
        btnTaskPause.setVisibility(View.VISIBLE);
        btnTaskStop.setVisibility(View.VISIBLE);
        TaskControl c = TaskCenter.current();
        if (c == null) {
            return;
        }
        int percent = c.percent();
        progressBar.setProgress(percent < 0 ? 0 : percent);
        statusText.setText(c.summary());
        btnTaskPause.setText(c.isPaused() ? "继续" : "暂停");

        // 暂停且已有结果时才给出「预览」入口：用户不必等整批跑完
        PartialPreview p = TaskCenter.partial();
        int count = p == null ? 0 : p.count();
        boolean canPreview = c.isPaused() && count > 0;
        if (btnTaskPreview != null) {
            btnTaskPreview.setVisibility(canPreview ? View.VISIBLE : View.INVISIBLE);
            if (canPreview) {
                btnTaskPreview.setText("预览 " + count);
            }
        }
    }

    public void runTask(final Tasks.Job job, final Tasks.Callback callback) {
        runTask("任务", job, callback);
    }

    /**
     * 执行长任务：进度、暂停、停止由 {@link TaskCenter} 统一管理，
     * 任务跑在独立线程 + 前台服务里，退到后台/锁屏仍会继续。
     */
    public boolean runTask(String title, final Tasks.Job job, final Tasks.Callback callback) {
        return runTask(title, job, callback, null);
    }

    /**
     * 执行长任务，并允许「暂停时预览已获取部分」。
     *
     * @param partial 已获取部分的预览提供者；为 null 时面板不显示预览按钮。
     */
    public boolean runTask(String title, final Tasks.Job job, final Tasks.Callback callback,
                           final PartialPreview partial) {
        final TaskControl control = TaskCenter.begin(this, title);
        if (control == null) {
            toast("已有任务在执行，请稍候");
            return false;
        }
        // 必须在 begin 之后注册（begin 会清掉上一任务残留的提供者）
        TaskCenter.setPartial(partial);
        lastTaskStopped = false;
        partialHandoff = false;
        progressBar.setProgress(0);
        statusText.setText(title + "：准备中…");
        updateTaskPanel();
        Tasks.run(new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                return job.run();
            }
        }, new Tasks.Callback() {
            @Override
            public void done(final Object result, final Exception error) {
                TaskCenter.end();
                boolean stopped = control.isCancelledNow();
                lastTaskStopped = stopped;
                if (stopped) {
                    statusText.setText("已停止");
                    log(title + "：已停止", "warning");
                } else {
                    statusText.setText("就绪");
                }
                callback.done(result, error);
                if (logAdapter != null) {
                    logAdapter.notifyDataSetChanged();
                }
                updateTaskPanel();
                // 从暂停预览里接管：等当前任务彻底收尾后再起下一个任务
                final Runnable next = pendingAfterStop;
                pendingAfterStop = null;
                if (next != null) {
                    Tasks.main(next);
                }
            }
        });
        return true;
    }

    /**
     * 扫描结果快照目录。
     *
     * <p>扫描出来的文件列表原本只活在内存里，闪退 / 被系统杀掉就全没了，重开只看到
     * 「还没有音乐文件」。这里把上次结果落盘，启动时直接恢复（见 {@link #restoreSnapshot()}）。
     */
    private java.io.File scanDir() {
        return new java.io.File(getFilesDir(), "scan");
    }

    /** 当前列表是什么时候扫出来的（0 = 没扫过）。 */
    public long lastScanAt() {
        return repo.lastScanAt;
    }

    /** 把时间戳说成「3 小时前」这种话（文件页空状态用）。 */
    public static String agoText(long at) {
        if (at <= 0) {
            return "未知时间";
        }
        long diff = System.currentTimeMillis() - at;
        if (diff < 0) {
            diff = 0;
        }
        long min = diff / 60000L;
        if (min < 1) {
            return "刚刚";
        }
        if (min < 60) {
            return min + " 分钟前";
        }
        long hour = min / 60;
        if (hour < 24) {
            return hour + " 小时前";
        }
        return (hour / 24) + " 天前";
    }

    /** 启动时恢复上次扫描结果（没有快照 / 换了目录就什么都不做）。 */
    private void restoreSnapshot() {
        if (!repo.lastFiles.isEmpty()) {
            // 内存里已经有上次结果（recreate：换主题 / 深色开关 / 转屏）。
            // 此时 repo 是单例、数据还在，但 BrowsePage 是**新建的**、
            // 构造函数不会自己装配索引 —— 不 reload 的话库页就是空列表，
            // 显示「还没有音乐文件 / 扫描目录」，看起来像目录丢了。
            // 封面位图缓存是实例字段，重建后也是空的，由 requestCover() 重新补。
            migrateBitrateOnce();
            browsePage.reload();
            if (repo.lastStats != null) {
                organizePage.setScanSummary(repo.lastScanAt > 0
                        ? "上次扫描 " + agoText(repo.lastScanAt) + "：" + repo.lastStats.summary()
                        + "\n列表来自本地缓存，点「自动整理」可刷新"
                        : repo.lastStats.summary());
            }
            return;
        }
        android.net.Uri uri = repo.treeUri();
        if (uri == null) {
            return;
        }
        com.dsh.musicorganizer.core.ScanSnapshot snap =
                com.dsh.musicorganizer.core.ScanSnapshot.load(scanDir(), uri.toString());
        if (snap == null || snap.isEmpty()) {
            return;
        }
        repo.lastFiles.clear();
        repo.lastFiles.addAll(snap.files);
        repo.lastGroups.clear();
        repo.lastGroups.addAll(snap.groups);
        repo.lastStats = snap.stats;
        repo.lastScanAt = snap.savedAt;
        organizePage.setScanSummary("上次扫描 " + snap.ageText() + "：" + snap.stats.summary()
                + "\n列表来自本地缓存，点「自动整理」可刷新");
        // 快照读进来之后再清码率缓存 —— 清早了 lastFiles 还是空的，等于没清（v0.1.79 修）
        migrateBitrateOnce();
        browsePage.reload();
        log("已恢复上次扫描结果：" + snap.files.size() + " 个文件 / " + snap.groups.size()
                + " 组（" + snap.ageText() + "）", "info");
    }

    /**
     * 一次性迁移（v0.1.76 / v0.1.77）：老版本把系统报错的码率缓存进了快照。
     *
     * <p>VBR 文件上系统常把码率报成首帧值（171 kbps 的歌报成 32 kbps），这个错值进了
     * {@code VFile.cachedBitrateKbps} 后，补读队列看到「码率已有」就不再重读，界面会一直错下去。
     * 这里只清码率、保留标签/封面/时长，不会引起重扫；进过库页面的行会自动重新读一次。
     *
     * <p>键名带版本号：修法换了（v0.1.77 起 MP3 一律自己算）就换一个键，让上一版缓存下来的
     * 「仍旧错的」值也一起清掉。
     */
    private void migrateBitrateOnce() {
        if (repo.bool("bitrate_fix_v4", false)) {
            return;
        }
        repo.setBool("bitrate_fix_v4", true);
        for (VFile f : repo.lastFiles) {
            if (f != null && f.cachedBitrateKbps > 0) {
                f.cacheMeta(f.cachedTags, f.cachedHasCover, f.cachedHasLyrics,
                        f.cachedDurationMs, 0);
            }
        }
    }

    /**
     * 扫描过滤（v0.1.80）：按路径关键字剔除文件、按需忽略视频。
     *
     * <p>只影响扫描结果，不动文件本身。关键字存在偏好 {@code scan_skip} 里
     * （空格/逗号分隔），勾选「忽略视频」存 {@code scan_ignore_video}。
     */
    private List<VFile> applyScanFilters(List<VFile> files) {
        if (files == null || files.isEmpty()) {
            return files;
        }
        boolean ignoreVideo = repo.bool(SettingsPage.KEY_SCAN_IGNORE_VIDEO, true);
        String raw = repo.str(SettingsPage.KEY_SCAN_SKIP, "");
        List<String> keys = new ArrayList<String>();
        if (raw != null && !raw.trim().isEmpty()) {
            for (String part : raw.split("[,，;；\\s]+")) {
                String t = part.trim().toLowerCase();
                if (!t.isEmpty()) {
                    keys.add(t);
                }
            }
        }
        if (!ignoreVideo && keys.isEmpty()) {
            return files;
        }
        List<VFile> out = new ArrayList<VFile>(files.size());
        int skipped = 0;
        for (VFile f : files) {
            if (f == null) {
                continue;
            }
            if (f.dir) {
                out.add(f);
                continue;
            }
            if (ignoreVideo && isVideoFile(f)) {
                skipped++;
                continue;
            }
            if (!keys.isEmpty() && pathHits(f, keys)) {
                skipped++;
                continue;
            }
            out.add(f);
        }
        if (skipped > 0) {
            log("扫描过滤：跳过 " + skipped + " 个文件（路径关键字 " + keys.size()
                    + " 个" + (ignoreVideo ? " · 忽略视频" : "") + "）", "info");
        }
        return out;
    }

    private static boolean isVideoFile(VFile f) {
        String mime = f.mime == null ? "" : f.mime.toLowerCase();
        if (mime.startsWith("video/")) {
            return true;
        }
        String ext = f.ext();
        return "mp4".equals(ext) || "m4v".equals(ext) || "mov".equals(ext)
                || "avi".equals(ext) || "mkv".equals(ext) || "webm".equals(ext)
                || "flv".equals(ext) || "wmv".equals(ext);
    }

    private static boolean pathHits(VFile f, List<String> keys) {
        String path;
        try {
            path = f.pathAfterRoot();
        } catch (Throwable t) {
            path = f.name;
        }
        String low = (path == null ? "" : path).toLowerCase();
        for (String k : keys) {
            if (low.contains(k)) {
                return true;
            }
        }
        return false;
    }

    /** 当前是否有任务在跑（任务中心同一时间只允许一个）。 */
    public boolean isTaskBusy() {
        TaskControl c = TaskCenter.current();
        return c != null && !c.isFinished();
    }

    /**
     * 停止当前任务，并在它收尾后立刻执行下一段任务。
     * 用于「暂停 → 预览已获取部分 → 直接写入这些条目」：不能边跑匹配边写盘。
     */
    public void stopCurrentThenRun(final String title, final Tasks.Job job,
                                   final Tasks.Callback callback) {
        TaskControl c = TaskCenter.current();
        if (c == null || c.isFinished() || c.isCancelledNow()) {
            runTask(title, job, callback);
            return;
        }
        pendingAfterStop = new Runnable() {
            @Override
            public void run() {
                runTask(title, job, callback);
            }
        };
        partialHandoff = true;
        c.cancel();
        toast("已停止匹配，准备写入已获取部分…");
    }

    /**
     * 取用一次「用户已从暂停预览接管」标记。为 true 时，刚结束的匹配任务
     * 不应再弹自己的结果窗（用户已经在写入了）。
     */
    public boolean consumePartialHandoff() {
        boolean v = partialHandoff;
        partialHandoff = false;
        return v;
    }

    /**
     * 目录内容变了（整理搬动 / 改名 / 删除 / 导入）：让上次结果作废，并**自动重扫一次**。
     *
     * <p>以前这里只清空 {@code lastFiles} 就结束，用户整理完切到「库」看到的是
     * 「还没有音乐文件 / 扫描目录」—— 像是目录丢了，其实只是列表被清空、没人重扫。
     * 现在清空之后排一次静默扫描（只走 SAF 遍历 + 增量复用标签缓存，不读盘），
     * 列表几秒内自己回来。
     */
    public void invalidateScan() {
        repo.lastGroups.clear();
        repo.lastFiles.clear();
        organizePage.setScanSummary("目录内容已变化，正在重新扫描…");
        browsePage.reload();
        scheduleRescan();
    }

    /** 排一次静默重扫：任务中心忙时等它空出来（整理/写盘刚结束时任务可能还没完全释放）。 */
    private void scheduleRescan() {
        if (repo.treeUri() == null) {
            organizePage.setScanSummary("还没有选择目录，先在设置页「音乐库目录」里选一个");
            return;
        }
        if (rescanPending) {
            return;
        }
        rescanPending = true;
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (isTaskBusy()) {
                    handler.postDelayed(this, 800);
                    return;
                }
                rescanPending = false;
                scanGroups(true);
            }
        }, 500);
    }

    /** 整理页「文件名查重」入口：切到文件页再跑（结果对话框属于文件页）。 */
    public void findDuplicates() {
        switchTab(1);
        if (browsePage != null) {
            browsePage.startDuplicateScan();
        }
    }

    /**
     * 设置页「整理工具 → 文件名查重」入口（v0.1.74 起从音乐库页筛选条移来）。
     *
     * <p>与 {@link #findDuplicates()} 的区别：<b>不切页</b> —— 用户就在设置里点，
     * 没必要先跳回音乐库；结果对话框直接盖在设置页上。
     */
    public void runFileNameDedup() {
        if (browsePage != null) {
            browsePage.startDuplicateScan();
        }
    }

    /** 从整理页跳到设置页（整理选项 / 写入策略都在那里，v0.1.50 起全部收敛）。 */
    public void openSettingsTab() {
        switchTab(3);
    }

    /** 设置页「工具」入口：打开整理页（扫描 / 清理 / 批量标签等）。 */
    public void openOrganizeTab() {
        switchTab(0);
    }

    /** 设置页「工具」入口：打开运行日志页。 */
    public void openLogTab() {
        switchTab(2);
    }

    /** 删除/移动文件之后：扫描结果作废，并静默重扫一遍文件列表（不弹提示）。 */
    public void refreshBrowseAfterChange() {
        scanGroups(true);
    }

    /**
     * 只写标签/封面之后：文件数量没变，不必重扫整个目录（那会再走一遍 SAF 遍历）。
     * 只需让文件页按当前列表重建一次索引；标签缓存已由事务层按 docId 失效。
     */
    public void refreshBrowseTagOnly() {
        if (browsePage != null) {
            browsePage.reload();
        }
    }

    /**
     * 写标签 / 封面 / 歌词之后：只刷新改动过的那几首。
     *
     * <p>比 {@link #refreshBrowseTagOnly()} 更进一步 —— 连索引都不重建，
     * 所以「无标签」筛选下补完一首，列表只会少这一行，不会把整库标签重读一遍。
     */
    public void refreshBrowseTagOnly(List<VFile> changed) {
        if (browsePage != null) {
            browsePage.refreshFiles(changed);
        } else {
            refreshBrowseTagOnly();
        }
    }

    // ------------------------------------------------------------------
    // 扫描（整理页 + 文件页共用）
    // ------------------------------------------------------------------

    public void scanGroups(final boolean silent) {        runTask("扫描", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = safeStorage();
                boolean recursive = repo.bool("recursive", true);
                Scanner.Stats stats = new Scanner.Stats();
                List<TrackGroup> groups = scanGroupsAll(recursive,
                        repo.bool("skip_artist", true), stats);
                // 去重计数：某些系统会把同一文档返回多次，报出来便于用户判断
                // 「本机曲目数」和播放器不一致到底是重复条目还是真有两份文件
                final int[] dups = new int[]{0};
                List<VFile> files = scanMusicAll(recursive, progressCallback(),
                        cancelToken(), dups);
                // 根目录下没有音频、只有子文件夹时，非递归会扫出 0 个文件 ——
                // 用户看到的就是「扫描完成，共 0 个文件」，以为扫描坏了。
                // 这里自动改成递归重扫一遍，并把开关同步过去，让设置和结果一致。
                boolean autoRecursive = false;
                if (files.isEmpty() && !recursive) {
                    autoRecursive = true;
                    recursive = true;
                    stats = new Scanner.Stats();
                    groups = scanGroupsAll(true, repo.bool("skip_artist", true), stats);
                    files = scanMusicAll(true, progressCallback(), cancelToken(), dups);
                }
                // 扫描过滤（v0.1.80）：按路径关键字剔除、按需忽略视频文件。
                // 放在增量合并之前 —— 被过滤掉的文件不该进 lastFiles，否则列表里一直有它们。
                files = applyScanFilters(files);
                // 增量：上一次扫到的文件如果 size / lastModified 都没变，就把已经读过的标签
                // 接力到新对象上（增量同步判定）。这样重扫目录只是重走
                // SAF 遍历，不必再把整库标签读一遍。
                ScanMerge.Result merged = ScanMerge.merge(repo.lastFiles, files);
                files = merged.files;
                // 扫描阶段即读取标签（元数据读取是扫描流程的一环，随快照落盘；
                // 进库页面时标签已完整，不必滚动到哪读哪行）。已被增量合并接力到缓存的文件
                // 跳过，只补没读过的——重扫目录不会再把整库标签重读一遍。
                // 先清目录封面缓存：本轮要按最新目录结构判断「有无封面」，不能用上一轮旧结果。
                FolderCover.clear();
                readTagsDuringScan(st, files, progressCallback(), cancelToken());
                // 顺手落盘：崩溃 / 被杀之后再打开能立刻看到上次的列表，不必重扫
                try {
                    com.dsh.musicorganizer.core.ScanSnapshot.save(scanDir(),
                            String.valueOf(repo.treeUri()), root(), files, groups, stats);
                } catch (Throwable ignored) {
                    // 快照写失败不影响本次扫描结果（重开时重扫即可）
                }
                String summary = merged.summary()
                        + (dups[0] > 0 ? "，忽略重复 " + dups[0] + " 条" : "");
                return new Object[]{groups, files, stats, Boolean.valueOf(autoRecursive),
                        summary};
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    fail(error);
                    return;
                }
                Object[] arr = (Object[]) result;
                @SuppressWarnings("unchecked")
                List<TrackGroup> groups = (List<TrackGroup>) arr[0];
                @SuppressWarnings("unchecked")
                List<VFile> files = (List<VFile>) arr[1];
                Scanner.Stats stats = (Scanner.Stats) arr[2];
                boolean autoRecursive = arr.length > 3 && Boolean.TRUE.equals(arr[3]);
                String mergedSummary = arr.length > 4 ? String.valueOf(arr[4]) : "";
                if (autoRecursive) {
                    repo.setBool("recursive", true);
                    organizePage.setRecursive(true);
                    log("根目录没有音频文件，已自动改为「包含子文件夹」重扫", "info");
                }
                repo.lastGroups.clear();
                repo.lastGroups.addAll(groups);
                repo.lastFiles.clear();
                repo.lastFiles.addAll(files);
                repo.lastStats = stats;
                repo.lastScanAt = System.currentTimeMillis();
                // 目录结构可能变了（整理搬动 / 新建封面图）：目录封面缓存必须作废，
                // 否则新放进来的 cover.jpg 要等重启才认
                FolderCover.clear();
                organizePage.setScanSummary(stats.summary());
                browsePage.reload();
                // 「自动整理」按钮 = 扫描 + 整理（v0.1.99）：扫描完成后紧接着触发整理
                if (organizePage.consumePendingOrganize()) {
                    organizePage.doOrganize();
                }
                // 扫描完成后自动显示文件列表：不管是从设置里的整理工具还是授权后自动扫的，
                // 都把界面切回主界面「音乐库」（静默重扫除外，避免打断当前页操作）。
                if (!silent) {
                    switchTab(1);
                }
                log("扫描完成：" + stats.summary()
                        + (mergedSummary.isEmpty() ? "" : " · " + mergedSummary), "info");
                if (!silent) {
                    if (files.isEmpty()) {
                        message("没有找到音频文件",
                                "目录：" + repo.treeDisplayName() + "\n"
                                        + "已递归扫描子文件夹，仍然没有 mp3 / flac / m4a / wav 等文件。\n\n"
                                        + "可能原因：\n"
                                        + "· 选错了目录（选到了上一级或空的文件夹）\n"
                                        + "· 音频在别的位置\n"
                                        + "· 文件扩展名不在支持列表里");
                    } else {
                        toast("扫描完成：" + files.size() + " 个文件 / " + groups.size() + " 组待整理");
                    }
                }
            }
        });
    }

    /**
     * 扫描阶段读取标签（元数据读取是扫描流程的一环，随快照落盘）。
     *
     * <p>只给还没读过的音频文件读：增量合并已经把上一次的标签接力到缓存，
     * 这里 {@code metaCached()} 为真就跳过，所以重扫目录不必再把整库标签重读一遍。
     * 进度通过 {@link Progress} 回报（内部切主线程刷新任务面板），对应「读标签」这个阶段。读好的标签写进 {@code VFile} 缓存，
     * 随后 {@link com.dsh.musicorganizer.core.ScanSnapshot#save} 会一并持久化，
     * 库页面加载后标签即完整。
     *
     * <p><b>并发（v0.1.75）</b>：以前是一首一首串行读，一千多首就是一千多次 SAF 读取，
     * 每次都是「开文件 → 复制文件头 → 解析」，绝大部分时间在等 IO。现在走
     * {@link com.dsh.musicorganizer.net.Net#map} 4 路并发，每首用自己的临时文件和
     * 自己的 {@code VFile}，互不干扰；进度仍报「读取标签 X/Y」。
     *
     * <p>顺手把封面缩图落盘（{@link CoverCache}），库页面冷启动时不必再为每首重读文件头。
     */
    private void readTagsDuringScan(final Storage st, List<VFile> files,
                                    final Progress p, CancelToken token) {
        final List<VFile> todo = new ArrayList<VFile>();
        for (VFile f : files) {
            if (!f.dir && f.audio() && !f.metaCached()) {
                todo.add(f);
            }
        }
        final int total = todo.size();
        if (total == 0) {
            return; // 全部已有缓存（增量扫描），无需再读
        }
        final AtomicInteger done = new AtomicInteger();
        com.dsh.musicorganizer.net.Net.map(todo,
                com.dsh.musicorganizer.net.Net.READ_THREADS, token,
                new com.dsh.musicorganizer.net.Net.Work<VFile, Object>() {
                    @Override
                    public Object run(VFile f) {
                        try {
                            Scanner.Head head = Scanner.readHead(st, f);
                            byte[] art = head.cover;
                            // 没有内嵌封面时，再看同一目录下的封面图（cover.jpg / folder.jpg…）——
                            // 与库页面解码口径一致；否则「靠目录封面」的曲目会被判成无封面，列表里不显示。
                            if (art == null || art.length == 0) {
                                art = FolderCover.read(MainActivity.this, st, f);
                            }
                            boolean hasCover = art != null && art.length > 0;
                            // 歌词标志由 reload() 按同名 .lrc 重新判断，这里不带
                            f.cacheMeta(head.tags, hasCover, f.cachedHasLyrics);
                            // 顺手把缩好的小图落盘：下次进库页面直接读本地小文件，
                            // 不必再为每首复制 2MB 文件头重抠一遍封面。
                            if (hasCover) {
                                CoverCache.save(MainActivity.this, f, art);
                            }
                        } catch (Throwable ignored) {
                            // 单首读失败（坏文件 / provider 异常）只跳过这一首，不能让整次扫描失败
                        }
                        int d = done.incrementAndGet();
                        if (d == total || d % 8 == 0) {
                            p.onProgress(d, total, "读取标签 " + d + "/" + total);
                        }
                        return null;
                    }
                });
    }

    // ------------------------------------------------------------------
    // 更新检查（Gitee 优先 / GitHub 兜底）
    // ------------------------------------------------------------------

    /** 自动检查的最小间隔：一天。匿名调用 GitHub API 每小时只有 60 次配额，不能更勤。 */
    private static final long UPDATE_INTERVAL_MS = 24L * 60 * 60 * 1000;

    /** 更新检查专用的单线程池（daemon）：不占任务中心，失败也不会有副作用。 */
    private static java.util.concurrent.ExecutorService updatePool() {
        synchronized (MainActivity.class) {
            if (updateExecutor == null) {
                updateExecutor = java.util.concurrent.Executors.newSingleThreadExecutor(
                        new java.util.concurrent.ThreadFactory() {
                            @Override
                            public Thread newThread(Runnable r) {
                                Thread t = new Thread(r, "update-check");
                                t.setDaemon(true);
                                t.setPriority(Thread.MIN_PRIORITY);
                                return t;
                            }
                        });
            }
            return updateExecutor;
        }
    }

    private static java.util.concurrent.ExecutorService updateExecutor;

    /**
     * 顶栏提示：上次查到的远端版本比本机新时，副标题挂一行红字。
     * 只读本地缓存（不发请求），所以启动和每次检查完调用都很便宜。
     */
    public void refreshUpdateHint() {
        if (subtitleText == null || repo == null) {
            return;
        }
        String tag = repo.str(Repo.KEY_UPDATE_TAG, "");
        if (!tag.isEmpty() && AppUpdate.isNewer(versionName(), tag)) {
            subtitleText.setText("音乐文件整理工具 · 安卓版 v" + versionName()
                    + "　有新版本 " + AppUpdate.display(tag));
            subtitleText.setTextColor(UiKit.errColor());
        } else {
            subtitleText.setText("音乐文件整理工具 · 安卓版 v" + versionName());
            subtitleText.setTextColor(UiKit.subColor());
        }
    }

    /**
     * 启动时自动检查（每天最多一次）。
     *
     * <p>刻意做成「静默」：只有真的发现新版本才提示一句，网络失败 / 被限流一律只写日志，
     * 不弹窗、不打断正在进行的整理。开关在整理页「⑥ 关于与更新」里。
     */
    private void maybeAutoCheckUpdate() {
        if (repo == null) {
            return;
        }
        // 先按缓存显示，离线也能看到上次查到的结果
        refreshUpdateHint();
        if (!repo.bool(Repo.KEY_UPDATE_AUTO, true)) {
            return;
        }
        long last = repo.longVal(Repo.KEY_UPDATE_LAST, 0L);
        if (System.currentTimeMillis() - last < UPDATE_INTERVAL_MS) {
            return;
        }
        updatePool().execute(new Runnable() {
            @Override
            public void run() {
                final com.dsh.musicorganizer.net.UpdateClient.Result r =
                        com.dsh.musicorganizer.net.UpdateClient.fetchLatest();
                if (!r.ok()) {
                    log("自动检查更新失败（不影响使用）："
                            + (r.error == null ? "" : r.error.replace('\n', ' ')), "debug");
                    return;
                }
                repo.setLong(Repo.KEY_UPDATE_LAST, System.currentTimeMillis());
                repo.setStr(Repo.KEY_UPDATE_TAG, r.release.tag);
                final boolean newer = AppUpdate.isNewer(versionName(), r.release.version);
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        if (isFinishing()) {
                            return;
                        }
                        refreshUpdateHint();
                        if (newer) {
                            log("发现新版本 " + AppUpdate.display(r.release.version)
                                    + "（点顶部版本号可查看）", "info");
                            toast("有新版本 " + AppUpdate.display(r.release.version)
                                    + "，点顶部版本号查看");
                        }
                    }
                });
            }
        });
    }

    // ------------------------------------------------------------------
    // 提示 / 日志
    // ------------------------------------------------------------------

    public void toast(String msg) {
        Toast.makeText(this, msg, Toast.LENGTH_SHORT).show();
    }

    public void message(String title, String content) {
        new UiKit.Builder(this)
                .setTitle(title)
                .setMessage(content)
                .setPositiveButton("确定", null)
                .show();
    }

    public void confirm(String title, String message, final Runnable onOk) {
        new UiKit.Builder(this)
                .setTitle(title)
                .setMessage(message)
                .setPositiveButton("确定", new android.content.DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(android.content.DialogInterface d, int w) {
                        onOk.run();
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    /**
     * 三选一对话框：主操作 / 次操作 / 取消。
     *
     * <p>Android 的 AlertDialog 最多三个按钮，这里把它们按语义排好：
     * {@code okText} 是主操作（如「重新查询」），{@code altText} 是次操作
     * （如「先看其它结果」），传 null 就不显示；{@code onAlt} 同理。
     */
    public void choose(String title, String message,
                       String okText, final Runnable onOk,
                       String altText, final Runnable onAlt,
                       String cancelText) {
        AlertDialog.Builder b = new UiKit.Builder(this)
                .setTitle(title)
                .setMessage(message);
        if (okText != null) {
            b.setPositiveButton(okText, new android.content.DialogInterface.OnClickListener() {
                @Override
                public void onClick(android.content.DialogInterface d, int w) {
                    onOk.run();
                }
            });
        }
        if (altText != null) {
            b.setNeutralButton(altText, new android.content.DialogInterface.OnClickListener() {
                @Override
                public void onClick(android.content.DialogInterface d, int w) {
                    if (onAlt != null) {
                        onAlt.run();
                    }
                }
            });
        }
        b.setNegativeButton(cancelText == null ? "取消" : cancelText, null);
        b.show();
    }

    public void fail(Exception error) {
        String msg = TextUtil.shortError(error);
        // 界面只显示一行，但把完整堆栈也落盘：像「Attempt to read from null array」
        // 这种消息定位不到具体位置，下次排查只能靠堆栈。
        try {
            java.io.StringWriter sw = new java.io.StringWriter();
            error.printStackTrace(new java.io.PrintWriter(sw));
            AppLog.write(AppLog.levelOf("error"), "app", "任务失败堆栈：\n" + sw.toString());
        } catch (Throwable ignored) {
        }
        log("任务失败：" + msg, "error");
        statusText.setText("失败：" + msg);
        toast(msg);
    }

    @Override
    public void log(String message, String level) {
        // 先落盘：界面日志可能被「清空」或随进程消失，持久化那份要留得住
        AppLog.write(AppLog.levelOf(level), "app", message);
        // 主线程：直接追加 + 立即通知，两步都在同一帧内完成，ListView 不会看到「半截状态」。
        if (Looper.myLooper() == Looper.getMainLooper()) {
            if (repo == null) {
                return;
            }
            repo.log(message, level);
            if (logAdapter != null) {
                logAdapter.notifyDataSetChanged();
            }
            return;
        }
        // 后台线程：只入队，由主线程统一追加并刷新（同时把高频日志合并成一次刷新）。
        synchronized (pendingLogs) {
            pendingLogs.add(new String[]{level, message});
            if (logFlushPosted) {
                return;
            }
            logFlushPosted = true;
        }
        Tasks.main(logFlush);
    }

    private final class LogAdapter extends android.widget.BaseAdapter {
        @Override
        public int getCount() {
            synchronized (repo.logLines) {
                return repo.logLines.size();
            }
        }

        @Override
        public Object getItem(int position) {
            synchronized (repo.logLines) {
                return repo.logLines.get(position);
            }
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            String[] entry;
            synchronized (repo.logLines) {
                if (position >= repo.logLines.size()) {
                    return new TextView(parent.getContext());
                }
                entry = repo.logLines.get(position);
            }
            String level = entry[0];
            String message = entry[1];
            int color;
            if ("error".equals(level)) {
                color = UiKit.errColor();
            } else if ("warning".equals(level)) {
                color = UiKit.warnColor();
            } else if ("success".equals(level)) {
                color = UiKit.okColor();
            } else {
                color = UiKit.textColor();
            }
            TextView tv;
            if (convertView instanceof TextView) {
                tv = (TextView) convertView;
            } else {
                tv = new TextView(parent.getContext());
                int pad = UiKit.dp(parent.getContext(), 8);
                tv.setPadding(pad, pad, pad, pad);
            }
            tv.setText(message);
            tv.setTextSize(13);
            tv.setTextColor(color);
            if ("success".equals(level)) {
                tv.setTypeface(Typeface.DEFAULT_BOLD);
            } else {
                tv.setTypeface(Typeface.DEFAULT);
            }
            return tv;
        }
    }
}
