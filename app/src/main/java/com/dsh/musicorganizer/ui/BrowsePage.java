package com.dsh.musicorganizer.ui;

import android.app.AlertDialog;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.media.MediaMetadataRetriever;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.text.style.StyleSpan;
import android.util.LruCache;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.TextView;

import com.dsh.musicorganizer.core.CoverReader;
import com.dsh.musicorganizer.core.Lyrics;
import com.dsh.musicorganizer.core.NameWeight;
import com.dsh.musicorganizer.core.Organizer;
import com.dsh.musicorganizer.core.Scanner;
import com.dsh.musicorganizer.core.SearchIndex;
import com.dsh.musicorganizer.core.SearchQuery;
import com.dsh.musicorganizer.core.Storage;
import com.dsh.musicorganizer.core.Tags;
import com.dsh.musicorganizer.core.TextUtil;
import com.dsh.musicorganizer.core.TrackInfo;
import com.dsh.musicorganizer.core.CoverCache;
import com.dsh.musicorganizer.core.VFile;
import com.dsh.musicorganizer.net.Net;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.io.File;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 文件页：浏览 / 搜索 / 排序筛选 / 多选批量 / 单文件操作。
 *
 * <p>三行式列表：标题（标签优先，缺失时用文件名）→ 艺人·专辑 → 路径·大小；右侧状态徽标。
 * 标签是<b>按需后台读</b>的：只有滚到可见的行才去读，避免进页面就为几千个文件各复制 2MB 文件头。
 *
 * <p>搜索走 {@link SearchIndex} 内存索引，支持空格分词、{@code artist:xxx} 字段前缀、
 * 大小比较（{@code size:>10m}），命中处高亮。
 */
public final class BrowsePage extends LinearLayout {

    private static final int FILTER_ALL = 0;
    private static final int FILTER_NO_TAG = 1;
    private static final int FILTER_NO_COVER = 2;
    private static final int FILTER_NO_LYRIC = 3;
    private static final String[] FILTER_LABELS = {"全部", "无标签", "无封面", "无歌词"};

    private static final int SORT_NAME = 0;
    private static final int SORT_SIZE = 1;
    private static final int SORT_TIME = 2;
    private static final int SORT_COMPLETE = 3;
    private static final int SORT_PATH = 4;
    private static final String[] SORT_LABELS = {"文件名", "大小", "修改时间", "标签完整度", "路径"};

    /** 一次后台读标签处理的文件数：太少来回起任务，太多一次卡太久。 */
    private static final int META_BATCH = 40;

    /** 读封面时只复制文件前 2MB：封面都在头部，整文件复制在几百首批量读下会打满 IO。 */
    private static final int COVER_HEAD_BYTES = 2 * 1024 * 1024;

    /** 列表封面图的目标宽度（px）：48dp 在 3x 屏上约 144px，取 96 再用两档缩放足够。 */
    private static final int COVER_PX = 96;

    /**
     * 封面图缓存（{@code docId → Bitmap}）。
     *
     * <p>ListView 复用行视图时会反复要同一张图，没有缓存就意味着每滑过一次就重新解码一次。
     * 用框架的 LruCache，按 1/8 可用内存给上限 —— 封面已经缩到 96px，这个配额能存几百张。
     */
    private final LruCache<String, Bitmap> coverCache =
            new LruCache<String, Bitmap>(Math.max(4 * 1024 * 1024,
                    (int) (Runtime.getRuntime().maxMemory() / 8L))) {
                @Override
                protected int sizeOf(String key, Bitmap value) {
                    return value == null ? 0 : value.getByteCount();
                }
            };

    private final MainActivity host;
    private final EditText searchBox;
    private final TextView countText;
    private final ListView listView;
    private final RowAdapter adapter;
    private final LinearLayout emptyState;
    private final TextView emptyTitle;
    private final TextView emptyHint;
    private final Button emptyAction;
    /** 空状态第二个动作（「清空搜索」）；只有「有列表但没匹配」时才显示。 */
    private final Button emptyAction2;
    private final LinearLayout batchBar;
    private final TextView batchCount;
    /** 「全选 / 取消全选」切换按钮（v0.1.56：同一个按钮，按当前选择状态改文案）。 */
    private TextView batchSelectAll;
    /** 多选时的悬浮操作按钮：圆形 + 号，右下角（圆形悬浮按钮）。 */
    private TextView batchFab;

    // ---- 下拉刷新指示器（小胶囊 + 旋转箭头）----
    private LinearLayout pullPill;
    private TextView pullArrow;
    private TextView pullLabel;
    private android.animation.ObjectAnimator pullSpin;
    private boolean pullRefreshing;
    /** 下拉多远才触发刷新：约 3cm（1cm≈63dp @160dp/inch）。 */
    private static final int PULL_THRESHOLD_DP = 190;
    /** 只保留「全部 / 无标签 / 无封面 / 无歌词」；排序已移到顶栏右上角，查重已移进设置。 */
    private final TextView[] filterChips = new TextView[FILTER_LABELS.length];

    private final SearchIndex index = new SearchIndex();
    private final List<SearchIndex.Entry> shown = new ArrayList<SearchIndex.Entry>();
    private final Set<String> selected = new HashSet<String>();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private Runnable pendingSearch;

    private SearchQuery query = SearchQuery.parse("");
    private int filter;
    private int sortKey;
    private boolean sortDesc;
    private boolean selectMode;
    /**
     * 滑动区间选择的锚点（长按那行的下标）；-1 = 当前没有在拖选。
     *
     * <p>手势：长按进入多选并记下锚点 → 手指不放继续上下滑 → 经过的行整段选中。
     * 抬手结束。列表照常滚动，所以在几千首里拖过一屏再拖回来也能连续选。
     */
    private int rangeAnchor = -1;
    private int rangeLast = -1;
    private boolean rangeDragging;
    /** 本轮搜索为了找结果自动摘掉了筛选（计数行要说明，免得用户以为筛选坏了）。 */
    private boolean droppedFilter;

    // 按需读标签：队列 + 在途集合，保证同一文件不会被重复排队
    private final ArrayDeque<SearchIndex.Entry> metaQueue = new ArrayDeque<SearchIndex.Entry>();
    private final Set<String> metaPending = new HashSet<String>();
    private boolean metaRunning;

    /**
     * 补封面用的队列（v0.1.52）。
     *
     * <p>为什么要单独一条队列：标签有磁盘缓存（{@code VFile.metaCached()}），重启 or
     * 换主题后 {@code reload()} 会把缓存直接套到新条目上、{@code metaLoaded=true}，
     * 于是 {@link #requestMeta} 直接返回 —— 而封面位图缓存是**内存里的实例字段**，
     * 重建后是空的，结果就是「标签都在、封面永远空白」。
     * 这里只补位图，不重读标签。
     */
    private final ArrayDeque<SearchIndex.Entry> coverQueue =
            new ArrayDeque<SearchIndex.Entry>();
    private final Set<String> coverPending = new HashSet<String>();
    /**
     * 本轮列表已经尝试补过封面的 docId（不管成功与否）。
     *
     * <p>为什么不靠 {@code cachedHasCover} 当门槛：旧版本（v0.1.65）的扫描只认内嵌封面，
     * 会把「靠目录封面 cover.jpg」的曲目误标成无封面，并随快照落盘、被增量合并一直沿用 ——
     * 于是补图队列永远跳过它们，封面就一直空白。这里改成「按实际解码结果说话」：
     * 每首每轮只试一次，能解出来就显示，解不出来就算了。
     */
    private final Set<String> coverTried = new HashSet<String>();
    private boolean coverRunning;
    /** 一次补几张：封面解码比读标签轻，但也不能一口气几百张把主线程 notify 打爆。 */
    private static final int COVER_BATCH = 8;

    /**
     * 时长 / 码率队列（v0.1.54）。
     *
     * <p>这两项要走系统的 {@code MediaMetadataRetriever}，每首上百毫秒，
     * 全库预读会拖到十几分钟。改成只给**当前可见行**补，滚动到哪读到哪。
     */
    private final ArrayDeque<SearchIndex.Entry> audioQueue =
            new ArrayDeque<SearchIndex.Entry>();
    private final Set<String> audioPending = new HashSet<String>();
    private boolean audioRunning;
    private static final int AUDIO_BATCH = 6;

    /** 全量预读上限：超过就不预热了，滚到哪读到哪。 */
    private static final int BULK_MAX = 3000;

    /**
     * 后台读标签用的单线程：只读、可随时丢弃、**不占任务中心的任务槽**。
     *
     * <p>走任务中心的问题：它一次只允许一个任务，且每次开始/结束都会刷新底栏与通知栏；
     * 而「滚到哪读到哪」是一批 40 个文件的碎片活，能连着起几十次 —— 底栏就不停地抖。
     */
    private static final java.util.concurrent.ExecutorService META_POOL =
            java.util.concurrent.Executors.newSingleThreadExecutor(
                    new java.util.concurrent.ThreadFactory() {
                        @Override
                        public Thread newThread(Runnable r) {
                            Thread t = new Thread(r, "browse-meta");
                            t.setDaemon(true);
                            t.setPriority(Thread.MIN_PRIORITY);
                            return t;
                        }
                    });

    /** 每次 reload 自增：在途的旧读取结果凭这个直接丢弃，不会贴到新列表上。 */
    private volatile int metaGen;
    private boolean bulkRunning;
    private boolean bulkDone;
    private int bulkDoneCount;
    private int bulkTotal;
    private final Runnable metaRetry = new Runnable() {
        @Override
        public void run() {
            drainMeta();
        }
    };
    /** 有任务在跑时的时长补读重试。 */
    private final Runnable audioRetry = new Runnable() {
        @Override
        public void run() {
            drainAudio();
        }
    };
    /** 有任务在跑时的封面补读重试（与标签重试分开，避免互相顶掉）。 */
    private final Runnable coverRetry = new Runnable() {
        @Override
        public void run() {
            drainCover();
        }
    };

    public BrowsePage(MainActivity host) {
        super(host);
        this.host = host;
        setOrientation(VERTICAL);
        int pad = UiKit.dp(getContext(), 12);
        setPadding(pad, pad, pad, pad);

        filter = host.repo.intVal("browse_filter", FILTER_ALL);
        sortKey = host.repo.intVal("browse_sort", SORT_NAME);
        sortDesc = host.repo.bool("browse_desc", false);

        // ---- 第一行：搜索框（左「🔍 搜索」提示，右「✕」一键清空；其他不显示）----
        LinearLayout toolbar = UiKit.horizontal(getContext());
        toolbar.setGravity(Gravity.CENTER_VERTICAL);

        LinearLayout searchWrap = UiKit.horizontal(getContext());
        searchWrap.setGravity(Gravity.CENTER_VERTICAL);
        GradientDrawable searchBg = new GradientDrawable();
        searchBg.setColor(UiKit.bgColor());
        searchBg.setCornerRadius(UiKit.dp(getContext(), 999));
        searchBg.setStroke(UiKit.dp(getContext(), 1), UiKit.lineColor());
        searchWrap.setBackground(searchBg);
        int sPadH = UiKit.dp(getContext(), 14);
        searchWrap.setPadding(sPadH, 0, sPadH, 0);

        searchBox = UiKit.input(getContext(), "🔍  搜索");
        searchBox.setSingleLine(true);
        // 背景交给外层圆角胶囊，输入框本身透明
        searchBox.setBackgroundColor(Color.TRANSPARENT);
        searchBox.setPadding(0, UiKit.dp(getContext(), 8), 0, UiKit.dp(getContext(), 8));

        final TextView clearX = UiKit.text(getContext(), "✕", 15, UiKit.subColor(), false);
        clearX.setPadding(UiKit.dp(getContext(), 10), UiKit.dp(getContext(), 8),
                0, UiKit.dp(getContext(), 8));
        clearX.setVisibility(View.GONE);
        clearX.setContentDescription("清空搜索");
        clearX.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                searchBox.setText("");
            }
        });

        searchBox.addTextChangedListener(new android.text.TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence s, int a, int b, int c) {
            }

            @Override
            public void onTextChanged(CharSequence s, int a, int b, int c) {
            }

            @Override
            public void afterTextChanged(android.text.Editable s) {
                clearX.setVisibility(s.length() > 0 ? View.VISIBLE : View.GONE);
                scheduleSearch();
            }
        });

        searchWrap.addView(searchBox, new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        searchWrap.addView(clearX);
        toolbar.addView(searchWrap, new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        // 「刷新」按钮去掉：改成下拉刷新（见下面 ListView 的触摸处理）
        addView(toolbar);

        // ---- 第二行：筛选 chip（可横向滚动）。排序在顶栏右上角，查重在设置 → 整理工具 ----
        HorizontalScrollView scrollChips = new HorizontalScrollView(getContext());
        scrollChips.setHorizontalScrollBarEnabled(false);
        LinearLayout chips = UiKit.horizontal(getContext());
        chips.setPadding(0, UiKit.dp(getContext(), 8), 0, 0);
        for (int i = 0; i < FILTER_LABELS.length; i++) {
            final int which = i;
            TextView chip = UiKit.chip(getContext(), FILTER_LABELS[i], filter == i);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            if (i > 0) {
                lp.setMargins(UiKit.dp(getContext(), 8), 0, 0, 0);
            }
            chips.addView(chip, lp);
            chip.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    filter = filter == which ? FILTER_ALL : which;
                    host.repo.setInt("browse_filter", filter);
                    syncChips();
                    if (filter == FILTER_NO_TAG || filter == FILTER_NO_COVER) {
                        ensureBulkMeta();
                    }
                    applyFilter();
                }
            });
            filterChips[i] = chip;
        }
        scrollChips.addView(chips);
        addView(scrollChips);

        // ---- 第三行：计数 ----
        // 必须是单行：这段文字会随「已读 x/y」「匹配「…」「已选 n」不断变长，
        // 一旦折成两行，下面的列表就整体往下跳一格。
        countText = UiKit.caption(getContext(), "");
        countText.setSingleLine(true);
        countText.setEllipsize(android.text.TextUtils.TruncateAt.END);
        UiKit.margin(countText, 0, 8, 0, 0);
        addView(countText);

        // ---- 列表 ----
        adapter = new RowAdapter();
        // 下拉刷新：列表已在顶部时继续下拉超过阈值 → 重新扫描目录。
        // 不引第三方 SwipeRefreshLayout（本项目零依赖），在 onTouchEvent 里观测手势后再交给 ListView。
        listView = new ListView(getContext()) {
            private float pullDownY;
            private float pullDist;

            @Override
            public boolean onTouchEvent(android.view.MotionEvent ev) {
                int threshold = UiKit.dp(getContext(), PULL_THRESHOLD_DP);
                // 多选态的拖选：长按后不抬手继续上下滑，经过的行整段选中。
                // 必须在 super 之前处理 —— 抬手后 ListView 会自己清掉按压状态。
                if (selectMode && rangeDragging) {
                    if (ev.getActionMasked() == android.view.MotionEvent.ACTION_MOVE) {
                        int pos = pointToPosition((int) ev.getX(), (int) ev.getY());
                        if (pos != android.widget.AdapterView.INVALID_POSITION && pos != rangeLast) {
                            extendRange(pos);
                        }
                    } else if (ev.getActionMasked() == android.view.MotionEvent.ACTION_UP
                            || ev.getActionMasked() == android.view.MotionEvent.ACTION_CANCEL) {
                        rangeDragging = false;
                    }
                }
                switch (ev.getActionMasked()) {
                    case android.view.MotionEvent.ACTION_DOWN:
                        pullDownY = ev.getY();
                        pullDist = 0f;
                        break;
                    case android.view.MotionEvent.ACTION_MOVE:
                        // 多选态不触发下拉刷新：这里下拉的意图是「拖选」，两件事会打架
                        if (pullRefreshing || selectMode) {
                            break;
                        }
                        boolean atTop = false;
                        if (getFirstVisiblePosition() == 0) {
                            View first = getChildAt(0);
                            atTop = first == null || first.getTop() >= 0;
                        }
                        if (!atTop) {
                            pullDist = 0f;
                            hidePullHint();
                            break;
                        }
                        pullDist = Math.max(0f, ev.getY() - pullDownY);
                        if (pullDist > 0) {
                            showPullHint(pullDist, threshold);
                        }
                        break;
                    case android.view.MotionEvent.ACTION_UP:
                    case android.view.MotionEvent.ACTION_CANCEL:
                        boolean trigger = pullDist >= threshold && !pullRefreshing
                                && !host.isTaskBusy();
                        pullDist = 0f;
                        if (trigger) {
                            startPullRefresh();
                        } else {
                            hidePullHint();
                        }
                        break;
                    default:
                        break;
                }
                return super.onTouchEvent(ev);
            }
        };
        listView.setAdapter(adapter);
        listView.setDivider(null);
        listView.setOnItemClickListener(new android.widget.AdapterView.OnItemClickListener() {
            @Override
            public void onItemClick(android.widget.AdapterView<?> parent, View view,
                                    int position, long id) {
                onRowClicked(shown.get(position));
            }
        });
        listView.setOnItemLongClickListener(
                new android.widget.AdapterView.OnItemLongClickListener() {
                    @Override
                    public boolean onItemLongClick(android.widget.AdapterView<?> parent,
                                                   View view, int position, long id) {
                        SearchIndex.Entry e = shown.get(position);
                        if (!selectMode) {
                            setSelectMode(true);
                        }
                        // 锚点行一律「置为选中」而不是切换：长按后接着往下拖时，
                        // 若这里刚好把它取消掉，整段选择的第一步就自我抵消了。
                        if (!selected.contains(e.docId)) {
                            selected.add(e.docId);
                            refreshSelectionUi();
                            adapter.notifyDataSetChanged();
                        }
                        rangeAnchor = position;
                        rangeLast = position;
                        rangeDragging = true;
                        return true;
                    }
                });
        // 列表外层套 FrameLayout：好把「多选操作 FAB」悬浮在列表右下角
        FrameLayout listWrap = new FrameLayout(getContext());
        listView.setLayoutParams(new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));
        listWrap.addView(listView);

        // 下拉刷新指示器（小胶囊 + 旋转箭头，跟手出现、越拉越转）
        pullPill = UiKit.horizontal(getContext());
        pullPill.setGravity(Gravity.CENTER_VERTICAL);
        GradientDrawable pullBg = new GradientDrawable();
        pullBg.setColor(UiKit.primarySoft());
        pullBg.setCornerRadius(UiKit.dp(getContext(), 999));
        pullPill.setBackground(pullBg);
        int ppH = UiKit.dp(getContext(), 14);
        int ppV = UiKit.dp(getContext(), 7);
        pullPill.setPadding(ppH, ppV, ppH, ppV);
        pullArrow = UiKit.text(getContext(), "↻", 17, UiKit.primary(), true);
        pullPill.addView(pullArrow);
        pullLabel = UiKit.text(getContext(), "下拉刷新", 12.5f, UiKit.primary(), false);
        UiKit.margin(pullLabel, 6, 0, 0, 0);
        pullPill.addView(pullLabel);
        FrameLayout.LayoutParams pullLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT);
        pullLp.gravity = Gravity.TOP | Gravity.CENTER_HORIZONTAL;
        pullLp.topMargin = UiKit.dp(getContext(), 8);
        pullPill.setLayoutParams(pullLp);
        pullPill.setVisibility(View.GONE);
        pullPill.setAlpha(0f);
        listWrap.addView(pullPill);

        batchFab = UiKit.fab(getContext(), "+");
        FrameLayout.LayoutParams fabLp = new FrameLayout.LayoutParams(
                UiKit.dp(getContext(), 56), UiKit.dp(getContext(), 56));
        fabLp.gravity = Gravity.BOTTOM | Gravity.END;
        int fm = UiKit.dp(getContext(), 16);
        // 底部再多留 ~1.5cm（≈95dp）：原先贴着列表底部，单手拇指够不到，整体上移
        fabLp.setMargins(fm, fm, fm, fm + UiKit.dp(getContext(), 95));
        batchFab.setLayoutParams(fabLp);
        batchFab.setVisibility(GONE);
        batchFab.setContentDescription("批量操作");
        batchFab.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (selected.isEmpty()) {
                    host.toast("先勾选文件");
                    return;
                }
                BatchMenuDialog.showForSelection(host, new BatchMenuDialog.SelectionHost() {
                    @Override
                    public int selectedCount() {
                        return selected.size();
                    }

                    @Override
                    public int totalCount() {
                        return shown.size();
                    }

                    @Override
                    public List<VFile> selectedFiles() {
                        return BrowsePage.this.selectedFiles();
                    }

                    @Override
                    public void toggleSelectAll() {
                        if (selected.size() >= shown.size() && !shown.isEmpty()) {
                            selected.clear();
                        } else {
                            selected.clear();
                            for (SearchIndex.Entry e : shown) {
                                selected.add(e.docId);
                            }
                        }
                        refreshSelectionUi();
                        adapter.notifyDataSetChanged();
                    }

                    @Override
                    public void exitSelection() {
                        setSelectMode(false);
                    }
                });
            }
        });
        listWrap.addView(batchFab);
        LinearLayout.LayoutParams wrapLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f);
        wrapLp.setMargins(0, UiKit.dp(getContext(), 6), 0, 0);
        listWrap.setLayoutParams(wrapLp);
        addView(listWrap);

        // ---- 空状态 ----
        emptyState = UiKit.vertical(getContext());
        emptyState.setGravity(Gravity.CENTER);
        emptyState.setPadding(0, UiKit.dp(getContext(), 24), 0, 0);
        emptyTitle = UiKit.text(getContext(), "", 15, UiKit.textColor(), true);
        emptyTitle.setGravity(Gravity.CENTER);
        emptyState.addView(emptyTitle);
        emptyHint = UiKit.caption(getContext(), "");
        emptyHint.setGravity(Gravity.CENTER);
        UiKit.margin(emptyHint, 0, 6, 0, 0);
        emptyState.addView(emptyHint);
        // 两个动作并排：搜不到时最该做的是「重新扫描」，其次才是「清空搜索」
        LinearLayout emptyRow = UiKit.horizontal(getContext());
        emptyRow.setGravity(Gravity.CENTER);
        emptyAction = UiKit.button(getContext(), "扫描目录", true);
        emptyAction2 = UiKit.button(getContext(), "清空搜索", false);
        emptyRow.addView(emptyAction);
        LinearLayout.LayoutParams a2lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        a2lp.setMargins(UiKit.dp(getContext(), 8), 0, 0, 0);
        emptyRow.addView(emptyAction2, a2lp);
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        alp.setMargins(0, UiKit.dp(getContext(), 12), 0, 0);
        alp.gravity = Gravity.CENTER_HORIZONTAL;
        emptyState.addView(emptyRow, alp);
        emptyAction.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                host.scanGroups(false);
            }
        });
        emptyAction2.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                clearSearch();
            }
        });
        emptyState.setVisibility(GONE);
        addView(emptyState);

        // ---- 多选操作条（v0.1.56）----
        // 以前是一排横向滚动的小按钮，一屏放不下还得左右滑。现在改成：
        // 顶部「已选 N 项 + 取消全选 + 关闭」，下面只留一个「操作」入口，
        // 点开是竖排清单（见 BatchMenuDialog）。
        batchBar = UiKit.vertical(getContext());
        batchBar.setVisibility(GONE);
        LinearLayout headRow = UiKit.horizontal(getContext());
        headRow.setGravity(Gravity.CENTER_VERTICAL);
        batchCount = UiKit.text(getContext(), "", 14, UiKit.primary(), true);
        headRow.addView(batchCount, new LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f));

        batchSelectAll = UiKit.text(getContext(), "全选", 14, UiKit.primary(), false);
        int tapPad = UiKit.dp(getContext(), 10);
        batchSelectAll.setPadding(tapPad, tapPad, tapPad, tapPad);
        batchSelectAll.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (selected.size() >= shown.size() && !shown.isEmpty()) {
                    selected.clear();
                } else {
                    selected.clear();
                    for (SearchIndex.Entry e : shown) {
                        selected.add(e.docId);
                    }
                }
                refreshSelectionUi();
                adapter.notifyDataSetChanged();
            }
        });
        headRow.addView(batchSelectAll);

        TextView closeBtn = UiKit.text(getContext(), "关闭", 14, UiKit.subColor(), false);
        closeBtn.setPadding(tapPad, tapPad, 0, tapPad);
        closeBtn.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                setSelectMode(false);
            }
        });
        headRow.addView(closeBtn);
        batchBar.addView(headRow);
        // 与搜索胶囊留一点呼吸，避免两行贴在一起
        UiKit.margin(batchBar, 0, 2, 0, 2);
        // 批量操作入口改成右下角圆形「+」FAB（见 listWrap 里的 batchFab），这里不再放占位按钮
        // 位置：紧贴搜索框下方（toolbar 是第 0 个子 View），长按后马上就能看到、拇指也够得到；
        // 放在列表后面（原实现）会被列表挤到屏幕最底部，多选时反而要往下去找。
        addView(batchBar, 1);

        syncChips();
    }

    // ------------------------------------------------------------------
    // 数据装配
    // ------------------------------------------------------------------

    /** 扫描完成 / 删除改名之后调用：重建索引并刷新列表。 */
    public void reload() {
        // 让在途的读标签结果作废：它们属于上一份列表，贴上来会把标题/艺人贴错行
        metaGen++;
        metaRunning = false;
        index.clear();
        metaQueue.clear();
        metaPending.clear();
        // 封面队列跟着一起作废；位图缓存按 docId 存，仍可继续用
        coverQueue.clear();
        coverPending.clear();
        coverTried.clear();
        handler.removeCallbacks(coverRetry);
        audioQueue.clear();
        audioPending.clear();
        handler.removeCallbacks(audioRetry);
        bulkDone = false;
        bulkRunning = false;
        bulkDoneCount = 0;
        bulkTotal = 0;
        handler.removeCallbacks(metaRetry);
        List<VFile> files = host.repo.lastFiles;
        // 先收集歌词文件，给同名音频打「有歌词」标记（不需要读盘）
        Map<String, Boolean> lrcStems = new HashMap<String, Boolean>();
        for (VFile f : files) {
            if (f.lyric()) {
                lrcStems.put(dirKey(f) + "/" + f.stem().toLowerCase(Locale.ROOT),
                        Boolean.TRUE);
            }
        }
        for (VFile f : files) {
            if (f.dir || !f.audio()) {
                continue;
            }
            SearchIndex.Entry e = new SearchIndex.Entry(f.docId, f.name,
                    f.pathAfterRoot(), f.size, f.lastModified, f);
            boolean hasLrc =
                    lrcStems.containsKey(dirKey(f) + "/" + f.stem().toLowerCase(Locale.ROOT));
            if (hasLrc) {
                e.hasLyrics = true;
            }
            // 库索引缓存：上次读过的标签直接套用。重建索引（reload）原来会把所有行退回
            // 「未读标签」，于是补完一首歌就要把整个目录的标签重读一遍 —— 现在只有真正
            // 没读过的文件才进按需读取队列。
            // 回填交给 TrackRestore：标签 / 封面 / 歌词 / 时长 / 码率是一组，
            // 只填一半会出现「换主题后时长和封面一起消失」。
            if (com.dsh.musicorganizer.core.TrackRestore.apply(e, f, hasLrc)) {
                // 已经填好，无需再读盘
            }
            index.add(e);
        }
        if (selectMode) {
            selected.clear();
            refreshSelectionUi();
        }
        applyFilter();
        // 列表装配完成后自动发起后台批量读标签：否则只有手动滑动页面、滚到哪行才读哪行，
        // 打开库页面会停在「标签已读 12/911」这种状态。批量读走后台单线程、非阻塞，
        // 进度会随读取自动涨到 911/911；已缓存的文件（reload 后）会直接命中缓存、几乎不花时间。
        ensureBulkMeta();
    }

    /**
     * 只刷新指定文件（写标签 / 封面 / 歌词之后调用）。
     *
     * <p><b>为什么不能直接 {@link #reload()}</b>：重建索引会把所有行退回「未读标签」，
     * 于是「无标签」筛选下补完一首歌，整张列表都会重新读一遍标签 —— 用户看到的就是
     * 「补一首歌要把整个目录重扫一次」。
     *
     * <p>这里只把改动的那几首重读一次并就地更新；筛选命中的集合重算即可，
     * 其它行的已读状态、排序、选中都不受影响。
     */
    public void refreshFiles(final List<VFile> changed) {
        if (changed == null || changed.isEmpty()) {
            reload();
            return;
        }
        final List<SearchIndex.Entry> need = new ArrayList<SearchIndex.Entry>();
        for (VFile f : changed) {
            if (f == null || f.dir) {
                continue;
            }
            SearchIndex.Entry e = index.find(f.docId);
            if (e == null) {
                // 索引里没有这一首（新增 / 改名 / 换了目录）：结构变了，只能重建
                reload();
                return;
            }
            // 文件刚被写过，旧缓存作废，读的时候才会真的回源
            f.clearMeta();
            need.add(e);
        }
        if (need.isEmpty()) {
            applyFilter();
            return;
        }
        final int gen = metaGen;
        META_POOL.execute(new Runnable() {
            @Override
            public void run() {
                List<Object[]> out = new ArrayList<Object[]>();
                try {
                    Storage st = host.repo.openStorage();
                    for (SearchIndex.Entry e : need) {
                        if (gen != metaGen) {
                            break;
                        }
                        out.add(readOneMeta(st, e));
                    }
                } catch (Throwable ignored) {
                }
                final List<Object[]> rows = out;
                handler.post(new Runnable() {
                    @Override
                    public void run() {
                        if (gen != metaGen) {
                            return; // 期间又扫描/重建过，这批结果属于旧列表
                        }
                        for (Object[] row : rows) {
                            applyRowMeta((SearchIndex.Entry) row[0], (Tags) row[1],
                                    ((Boolean) row[2]).booleanValue(),
                                    ((Long) row[3]).longValue(), ((Integer) row[4]).intValue(),
                                    (byte[]) row[5]);
                        }
                        // 重算命中集合：改完标签的那首会自然离开「无标签」筛选
                        applyFilter();
                    }
                });
            }
        });
    }

    private static String dirKey(VFile f) {
        String path = f.pathAfterRoot();
        int slash = path.lastIndexOf('/');
        return slash >= 0 ? path.substring(0, slash) : "";
    }

    private void scheduleSearch() {
        if (pendingSearch != null) {
            handler.removeCallbacks(pendingSearch);
        }
        pendingSearch = new Runnable() {
            @Override
            public void run() {
                applyFilter();
            }
        };
        handler.postDelayed(pendingSearch, 220);
    }

    private void applyFilter() {
        applyFilter(true);
    }

    /**
     * 重算列表。
     *
     * <p>{@code allowAutoFix} 为真时，一轮「无命中」会额外做两件补救 ——
     * 这两条正是「明明有这首歌却搜不到」的常见原因：
     * <ol>
     *   <li><b>筛选把它藏了</b>：筛选 chip 是记住的，用户上次点了「无标签」，
     *       下次进来说什么也搜不到。搜索的语义应该是「全库找我打的字」，
     *       所以这里直接摘掉筛选重搜一次，并在计数行注明「已忽略筛选」。</li>
     *   <li><b>标签还没读</b>：按需读标签是「滚到哪读到哪」，没读过的行
     *       歌手/专辑/歌词都是空的，搜「黄征」自然不中。这里补读一批再搜。</li>
     * </ol>
     */
    private void applyFilter(boolean allowAutoFix) {
        query = SearchQuery.parse(searchBox.getText().toString());
        if (query.hasFieldFilter() && !bulkDone) {
            // artist:xxx 这类条件必须读过标签才准，先补读一次再过滤
            ensureBulkMeta();
        }
        if (allowAutoFix) {
            droppedFilter = false;
        }
        List<SearchIndex.Entry> list = index.search(query);
        shown.clear();
        for (SearchIndex.Entry e : list) {
            if (passFilter(e)) {
                shown.add(e);
            }
        }
        // 扫描/整理完之后列表是空的，但筛选条件还停在「待补 / 无封面」这类上面：
        // 新扫出来的条目还没读标签，一条都不满足，看起来就像「刷新没反应」。
        // 搜索框为空时直接切回「全部」，并记下这次自动切换（计数行会说明）。
        if (allowAutoFix && shown.isEmpty() && query.isEmpty()
                && filter != FILTER_ALL && !index.all().isEmpty()) {
            filter = FILTER_ALL;
            droppedFilter = true;
            host.repo.setInt("browse_filter", filter);
            syncChips();
            list = index.search(query);
            shown.clear();
            for (SearchIndex.Entry e : list) {
                if (passFilter(e)) {
                    shown.add(e);
                }
            }
        }
        if (allowAutoFix && shown.isEmpty() && !query.isEmpty()) {
            if (filter != FILTER_ALL) {
                filter = FILTER_ALL;
                droppedFilter = true;
                host.repo.setInt("browse_filter", filter);
                syncChips();
                list = index.search(query);
                shown.clear();
                for (SearchIndex.Entry e : list) {
                    if (passFilter(e)) {
                        shown.add(e);
                    }
                }
            }
            if (shown.isEmpty() && !bulkDone && !bulkRunning) {
                // 补读完成后 finishBulk() 会再调一次 applyFilter()，结果会自动贴上来
                ensureBulkMeta();
            }
        }
        sortShown();
        adapter.notifyDataSetChanged();
        updateCountText();
        updateEmptyState();
    }

    /** 清掉搜索词与筛选，回到全量列表（空状态里的「清空搜索」）。 */
    private void clearSearch() {
        searchBox.setText("");
        filter = FILTER_ALL;
        host.repo.setInt("browse_filter", filter);
        syncChips();
        applyFilter();
    }

    private boolean passFilter(SearchIndex.Entry e) {
        if (filter == FILTER_NO_TAG) {
            return !e.metaLoaded || e.displayTitle().isEmpty() || e.artist.trim().isEmpty();
        }
        if (filter == FILTER_NO_COVER) {
            return e.metaLoaded && !e.hasCover;
        }
        if (filter == FILTER_NO_LYRIC) {
            return !e.hasLyrics;
        }
        return true;
    }

    private void sortShown() {
        Collections.sort(shown, new Comparator<SearchIndex.Entry>() {
            @Override
            public int compare(SearchIndex.Entry a, SearchIndex.Entry b) {
                int cmp;
                if (sortKey == SORT_SIZE) {
                    cmp = a.size < b.size ? -1 : (a.size == b.size ? 0 : 1);
                } else if (sortKey == SORT_TIME) {
                    cmp = a.modified < b.modified ? -1 : (a.modified == b.modified ? 0 : 1);
                } else if (sortKey == SORT_COMPLETE) {
                    cmp = (a.tagComplete() ? 1 : 0) - (b.tagComplete() ? 1 : 0);
                } else if (sortKey == SORT_PATH) {
                    cmp = a.relPath.compareToIgnoreCase(b.relPath);
                } else {
                    cmp = a.displayTitle().compareToIgnoreCase(b.displayTitle());
                }
                if (sortDesc) {
                    cmp = -cmp;
                }
                if (cmp == 0) {
                    cmp = a.docId.compareTo(b.docId);
                }
                return cmp;
            }
        });
    }

    private void updateCountText() {
        StringBuilder sb = new StringBuilder();
        sb.append("共 ").append(shown.size()).append(" 首");
        if (index.size() != shown.size() || !query.isEmpty()) {
            sb.append("（全部 ").append(index.size()).append(" 首）");
        }
        int loaded = index.loadedCount();
        if (bulkRunning && bulkTotal > 0) {
            // 预读进行中：进度直接写这一行，不用任务面板（面板一出现底栏就变高，会抖）
            sb.append(" · 读取标签 ").append(bulkDoneCount).append('/').append(bulkTotal);
        } else if (loaded < index.size()) {
            sb.append(" · 标签已读 ").append(loaded).append('/').append(index.size());
        }
        if (!query.isEmpty()) {
            sb.append(" · 匹配「").append(shortQuery()).append('」');
            if (droppedFilter) {
                sb.append(" · 已忽略筛选");
            }
        }
        if (selectMode) {
            sb.append(" · 已选 ").append(selected.size());
        }
        countText.setText(sb.toString());
    }

    private String shortQuery() {
        String s = searchBox.getText().toString().trim();
        return s.length() > 18 ? s.substring(0, 18) + "…" : s;
    }

    private void updateEmptyState() {
        boolean empty = shown.isEmpty();
        emptyState.setVisibility(empty ? VISIBLE : GONE);
        listView.setVisibility(empty ? GONE : VISIBLE);
        if (!empty) {
            return;
        }
        emptyAction.setText("扫描目录");
        if (index.size() == 0) {
            emptyTitle.setText("还没有音乐文件");
            emptyHint.setText("先在整理页选择文件夹，或点下面按钮扫描当前目录。");
            emptyAction2.setVisibility(GONE);
        } else if (bulkRunning) {
            // 搜不到 → 正在补读标签再搜一次（ensureBulkMeta 完成后会自动重算）
            emptyTitle.setText("正在读标签，再搜一次…");
            emptyHint.setText("标签只读到 " + bulkDoneCount + "/" + bulkTotal
                    + " 首时，歌手 / 专辑 / 歌词还没进索引。");
            emptyAction.setText("重新扫描");
            emptyAction2.setVisibility(VISIBLE);
        } else {
            emptyTitle.setText("没有匹配的文件");
            emptyHint.setText(emptyHintText());
            emptyAction.setText("重新扫描");
            emptyAction2.setVisibility(VISIBLE);
        }
    }

    /**
     * 「搜不到」时的说明 —— 这类问题九成不是搜索算法坏了，而是
     * ①列表本身没扫到这首（新下载 / 目录不对），②标签还没读（歌手名不在索引里）。
     * 所以这里把「列表哪来的、多旧、共几首、扫的哪个目录」直接摊开给用户看。
     */
    private String emptyHintText() {
        StringBuilder sb = new StringBuilder();
        sb.append("列表是 ").append(MainActivity.agoText(host.lastScanAt()))
                .append("扫描的，共 ").append(index.size()).append(" 首");
        String dir = host.repo.treeDisplayName();
        if (dir != null && !dir.isEmpty()) {
            sb.append("，目录 ").append(dir);
        }
        sb.append("。");
        if (index.loadedCount() < index.size()) {
            sb.append("\n标签只读了 ").append(index.loadedCount()).append('/').append(index.size())
                    .append(" 首，歌手 / 专辑可能还没进索引；点「重新扫描」或把列表滚一遍再搜。");
        } else {
            sb.append("\n刚下载 / 刚放进来的文件要重新扫描才会出现。");
        }
        // Android 11 起第三方应用读不到「下载」根目录（系统文件管理器有特权），
        // 这是「系统能搜到、别的 App 搜不到」最常见的原因，必须直接说出来
        sb.append("\n文件若在「下载」文件夹根目录，Android 11 起读不到，请移到 Music 等子文件夹再扫描。");
        sb.append("\n也可以只输歌名的一部分，或用 artist:艺人、album:专辑、ext:flac 这样的写法。");
        return sb.toString();
    }

    // ------------------------------------------------------------------
    // 按需读标签
    // ------------------------------------------------------------------

    /**
     * 后台补读标签（**不进任务中心**）。
     *
     * <p>为什么不用 {@code host.runTask}：任务中心同一时间只允许一个任务，每次开始/结束都会
     * 让底部状态栏和通知栏闪一下；而这里是「滚到哪读到哪」的碎片化小活，一批 40 个文件，
     * 几分钟内能起几十次 —— 底栏就不停地抖。所以走一条自己的静默单线程：
     * 只读、可随时丢弃、不占任务槽，也不会把用户想点的「扫描」挡掉。
     *
     * <p>代价是它没有暂停按钮；但每批只有 40 个文件、单线程、最低优先级，影响可忽略。
     */
    private void ensureBulkMeta() {
        if (bulkRunning || bulkDone || index.size() == 0) {
            return;
        }
        final List<SearchIndex.Entry> todo = new ArrayList<SearchIndex.Entry>();
        for (SearchIndex.Entry e : index.all()) {
            if (!e.metaLoaded && e.file != null) {
                todo.add(e);
            }
        }
        if (todo.isEmpty()) {
            bulkDone = true;
            return;
        }
        final int cap = Math.min(todo.size(), BULK_MAX);
        final int gen = metaGen;
        bulkRunning = true;
        bulkDoneCount = 0;
        bulkTotal = cap;
        updateCountText();
        META_POOL.execute(new Runnable() {
            @Override
            public void run() {
                // 并发收敛到 Net.map 里（每批自己一个小池，跑完即关，不与联网池共用）
                final List<Object[]> out =
                        Collections.synchronizedList(new ArrayList<Object[]>());
                final AtomicInteger done = new AtomicInteger();
                try {
                    final Storage st = host.repo.openStorage();
                    final List<SearchIndex.Entry> work = cap >= todo.size()
                            ? todo : new ArrayList<SearchIndex.Entry>(todo.subList(0, cap));
                    Net.map(work, Net.READ_THREADS, null,
                            new Net.Work<SearchIndex.Entry, Object>() {
                                @Override
                                public Object run(SearchIndex.Entry e) {
                                    if (gen != metaGen) {
                                        return null; // 列表已重建：这一轮作废，别再读盘
                                    }
                                    Object[] row = null;
                                    try {
                                        row = readOneMeta(st, e);
                                    } catch (Throwable ignored) {
                                        // 单首失败就当没读到，下次进页面还会再排
                                    }
                                    if (row != null) {
                                        out.add(row);
                                    }
                                    final int d = done.incrementAndGet();
                                    if (d % 10 == 0 || d == work.size()) {
                                        handler.post(new Runnable() {
                                            @Override
                                            public void run() {
                                                bulkDoneCount = d;
                                                updateCountText();
                                            }
                                        });
                                    }
                                    return row;
                                }
                            });
                } catch (Throwable ignored) {
                    // 读不到就当没读到：行里保持「读取标签…」，下次进页面还会再排
                }
                final List<Object[]> rows = out;
                handler.post(new Runnable() {
                    @Override
                    public void run() {
                        finishBulk(gen, rows);
                    }
                });
            }
        });
    }

    /** 全量读取结束：贴标签、复位状态、重算列表。 */
    private void finishBulk(int gen, List<Object[]> rows) {
        bulkRunning = false;
        if (gen != metaGen) {
            return;
        }
        bulkDone = true;
        for (Object[] row : rows) {
            applyRowMeta((SearchIndex.Entry) row[0], (Tags) row[1],
                    ((Boolean) row[2]).booleanValue(),
                    ((Long) row[3]).longValue(), ((Integer) row[4]).intValue(),
                    (byte[]) row[5]);
        }
        applyFilter();
    }

    /**
     * 把一次读盘结果贴到行上，同时回填到 {@link VFile} 的库索引缓存。
     *
     * <p>回填之后，下次 {@link #reload()}（扫描完成、改名、换排序）就不用再读这些文件。
     */
    private void applyRowMeta(SearchIndex.Entry e, Tags tags, boolean cover,
                              long durationMs, int bitrateKbps, byte[] art) {
        if (e == null) {
            return;
        }
        e.applyTags(tags, cover);
        // 批量预读不读时长（0 表示「还没读」），不要用它把已有的值覆盖掉
        if (durationMs > 0) {
            e.durationMs = durationMs;
        }
        if (bitrateKbps > 0) {
            e.bitrateKbps = bitrateKbps;
        }
        if (e.file != null) {
            e.file.cacheMeta(tags, cover, e.hasLyrics, e.durationMs, e.bitrateKbps);
        }
        if (art != null && art.length > 0) {
            Bitmap bmp = decodeCover(art);
            if (bmp != null) {
                coverCache.put(e.docId, bmp);
            }
        }
    }

    /**
     * 读一条曲目的全部展示信息（后台线程调用，别在主线程用）。
     *
     * <p>返回 {@code Object[]}：{@code [Entry, Tags, Boolean(hasCover),
     * Long(durationMs), Integer(bitrateKbps), byte[](封面)}。
     * 用数组而不是新建小类，是为了不改动三处调用点的集合类型。
     */
    /**
     * 读一条曲目的展示信息（后台线程）。
     *
     * <p><b>为什么不再读时长/码率</b>：那一步要开 {@code MediaMetadataRetriever}，
     * 每首 100~300ms，1213 首光这一项就十几分钟。现在批量预读只读标签 + 封面
     * （一次复制搞定），时长/码率由可见行单独排队补（见 {@link #requestAudioInfo}）。
     */
    private Object[] readOneMeta(Storage st, SearchIndex.Entry e) {
        Tags tags;
        byte[] art = null;
        boolean cover;
        if (e.file != null && e.file.metaCached()) {
            // 缓存直填：标签与「有无封面」都已知；位图由 requestCover 单独补
            tags = e.file.cachedTags.copy();
            cover = e.file.cachedHasCover;
        } else {
            Scanner.Head head = Scanner.readHead(st, e.file);
            tags = head.tags;
            art = head.cover;
            // 只有「整个标签都没解析出来」时才去问系统 —— 那种情况多半是我们的解析器
            // 不认识这个写法。标签读得好好的、只是没有 APIC，就说明文件确实没有内嵌封面，
            // 再开一次 MediaMetadataRetriever 纯属白花 100~300ms（全库就是十几分钟）。
            if (art == null && !tags.anyValue()) {
                art = retrieverArt(st, e.file);
            }
            if (art == null) {
                art = FolderCover.read(host, st, e.file);
            }
            cover = art != null && art.length > 0;
            // 顺手落盘（这里是后台线程）：下次重建列表可以直接读本地小图，
            // 不必再为这一首复制 2MB 文件头重抠封面。
            if (cover) {
                CoverCache.save(host, e.file, art);
            }
        }
        return new Object[]{e, tags, Boolean.valueOf(cover),
                Long.valueOf(0L), Integer.valueOf(0), art};
    }

    /**
     * 读封面，三级兜底（v0.1.54）：
     * <ol>
     *   <li>自研解析（ID3 APIC / FLAC PICTURE / MP4 covr）；</li>
     *   <li>系统 {@code MediaMetadataRetriever.getEmbeddedPicture()} —— 手写解析漏掉的写法它常能读到；</li>
     *   <li>同一目录下的封面图片（cover.jpg / folder.jpg / album.jpg …）。</li>
     * </ol>
     */
    private byte[] readCover(Storage st, VFile f) {
        byte[] art = readCoverArt(st, f);
        if (art != null && art.length > 0) {
            return art;
        }
        art = retrieverArt(st, f);
        if (art != null && art.length > 0) {
            return art;
        }
        return FolderCover.read(host, st, f);
    }

    /** 系统解析兜底：手写解析漏掉的标签写法，框架的 getEmbeddedPicture 常能拿到。 */
    private byte[] retrieverArt(Storage st, VFile f) {
        try {
            byte[] art = com.dsh.musicorganizer.core.MediaMeta.embeddedPicture(
                    host.getContentResolver(), st.documentUri(f));
            return art != null && art.length > 0 ? art : null;
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * 读时长与码率（框架的 {@link MediaMetadataRetriever}，MP3/FLAC/M4A/OGG/WAV/APE 都认）。
     *
     * <p>码率在框架里是 <b>bps</b>（如 320000），这里除 1000 转成 kbps 再交给界面显示。
     *
     * @return {@code [durationMs, bitrateKbps]}；取不到都是 0（界面据此不显示，而不是显示 0）
     */
    /** 时长 / 码率：实现搬到 {@link AudioInfo}，详情面板也要用。 */
    private long[] readAudioInfo(Storage st, VFile f) {
        return AudioInfo.read(host.getContentResolver(), st, f);
    }

    /** 读内嵌封面字节；没有或读不出来返回 null。 */
    private byte[] readCoverArt(Storage st, VFile f) {
        if (st == null || f == null) {
            return null;
        }
        File tmp = null;
        try {
            // 关键：临时文件必须带**真实音频扩展名**。CoverReader.read 是按扩展名分派的
            // （.mp3/.flac/.m4a），以前这里固定写 ".tmp"，于是永远解析不出来 → 列表封面全空。
            String ext = com.dsh.musicorganizer.core.TagIO.extOf(f.name);
            tmp = File.createTempFile("mo_cover_",
                    ext == null || ext.isEmpty() ? ".tmp" : ext);
            // 封面都在文件头部（MP3 的 APIC 在标签区、FLAC 的 picture block 紧随其后），
            // 只复制前 2MB —— 整文件复制在几百首的批量读取下会把 IO 打满
            int copied = st.copyHeadToLocal(f, tmp, COVER_HEAD_BYTES);
            // 大封面 / 大标签可能超出 2MB：与 Scanner.readHead 同口径回退整文件
            if (copied >= COVER_HEAD_BYTES
                    && !com.dsh.musicorganizer.core.TagIO.tagFitsCopy(tmp, ext)) {
                st.copyToLocal(f, tmp);
            }
            return CoverReader.read(tmp);
        } catch (Throwable t) {
            return null;
        } finally {
            if (tmp != null) {
                //noinspection ResultOfMethodCallIgnored
                tmp.delete();
            }
        }
    }

    /** 封面字节 → 列表用的小图（约 96px 宽）；失败返回 null。 */
    private static Bitmap decodeCover(byte[] bytes) {
        if (bytes == null || bytes.length == 0) {
            return null;
        }
        try {
            BitmapFactory.Options probe = new BitmapFactory.Options();
            probe.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(bytes, 0, bytes.length, probe);
            int width = probe.outWidth;
            if (width <= 0) {
                return null;
            }
            int sample = 1;
            while (width / (sample * 2) >= COVER_PX) {
                sample *= 2;
            }
            BitmapFactory.Options real = new BitmapFactory.Options();
            real.inSampleSize = sample;
            return BitmapFactory.decodeByteArray(bytes, 0, bytes.length, real);
        } catch (Throwable t) {
            return null;
        }
    }

    private static long parseLong(String s) {
        if (s == null) {
            return 0;
        }
        try {
            return Long.parseLong(s.trim());
        } catch (Exception e) {
            return 0;
        }
    }

    private void requestMeta(final SearchIndex.Entry e) {
        if (e == null || e.metaLoaded || e.file == null || metaPending.contains(e.docId)) {
            return;
        }
        if (metaQueue.size() > 400) {
            return;
        }
        metaPending.add(e.docId);
        metaQueue.add(e);
        drainMeta();
    }

    /** 从队列里取一批交给自己那条静默线程去读。 */
    private void drainMeta() {
        if (metaRunning || metaQueue.isEmpty()) {
            return;
        }
        if (host.isTaskBusy()) {
            // 有扫描/批量写盘在跑：别跟它抢磁盘，过一会儿再读
            handler.removeCallbacks(metaRetry);
            handler.postDelayed(metaRetry, 1200);
            return;
        }
        final List<SearchIndex.Entry> batch = new ArrayList<SearchIndex.Entry>();
        while (!metaQueue.isEmpty() && batch.size() < META_BATCH) {
            batch.add(metaQueue.poll());
        }
        metaRunning = true;
        final int gen = metaGen;
        META_POOL.execute(new Runnable() {
            @Override
            public void run() {
                final List<Object[]> out =
                        Collections.synchronizedList(new ArrayList<Object[]>());
                try {
                    final Storage st = host.repo.openStorage();
                    Net.map(batch, Net.READ_THREADS, null,
                            new Net.Work<SearchIndex.Entry, Object>() {
                                @Override
                                public Object run(SearchIndex.Entry e) {
                                    if (gen != metaGen) {
                                        return null;
                                    }
                                    Object[] row = null;
                                    try {
                                        row = readOneMeta(st, e);
                                    } catch (Throwable ignored) {
                                    }
                                    if (row != null) {
                                        out.add(row);
                                    }
                                    return row;
                                }
                            });
                } catch (Throwable ignored) {
                }
                final List<Object[]> rows = out;
                handler.post(new Runnable() {
                    @Override
                    public void run() {
                        finishMeta(gen, batch, rows);
                    }
                });
            }
        });
    }

    /** 一批读完了：贴标签 + 只重绘不重排（排序键没变，不能重排，否则列表会跳）。 */
    private void finishMeta(int gen, List<SearchIndex.Entry> batch, List<Object[]> rows) {
        metaRunning = false;
        if (gen != metaGen) {
            return; // 期间 reload 过，这批结果属于旧列表，直接丢
        }
        for (Object[] row : rows) {
            SearchIndex.Entry e = (SearchIndex.Entry) row[0];
            applyRowMeta(e, (Tags) row[1], ((Boolean) row[2]).booleanValue(),
                    ((Long) row[3]).longValue(), ((Integer) row[4]).intValue(),
                    (byte[]) row[5]);
            metaPending.remove(e.docId);
        }
        for (SearchIndex.Entry e : batch) {
            if (!e.metaLoaded) {
                // 没读到的放回可重排状态，滚动时还能再试
                metaPending.remove(e.docId);
            }
        }
        adapter.notifyDataSetChanged();
        updateCountText();
        if (!metaQueue.isEmpty()) {
            drainMeta();
        }
    }

    /**
     * 只补封面位图，不重读标签。
     *
     * <p>触发条件：这一条的标签已经在（{@code metaLoaded}，可能来自磁盘缓存直填），
     * 文件确实有封面，但内存里的位图缓存没有 —— 重建索引、换主题、冷启动都会出现这种情况。
     * 没有这条通路的话，缓存直填的条目永远不会去读封面，列表就一直是空占位。
     */
    private void requestCover(SearchIndex.Entry e) {
        // 不再用 hasCover 当门槛：旧快照里的封面标记可能是错的（目录封面被判成无封面），
        // 直接按实际解码结果决定；每首每轮只尝试一次，避免反复读盘。
        if (e == null || e.file == null || !e.metaLoaded) {
            return;
        }
        if (coverCache.get(e.docId) != null || coverPending.contains(e.docId)
                || coverTried.contains(e.docId)) {
            return;
        }
        if (coverQueue.size() > 300) {
            return;
        }
        coverTried.add(e.docId);
        coverPending.add(e.docId);
        coverQueue.add(e);
        drainCover();
    }

    /** 从封面队列取一小批，交给自己那条静默线程去读。 */
    private void drainCover() {
        if (coverRunning || coverQueue.isEmpty()) {
            return;
        }
        if (host.isTaskBusy()) {
            // 扫描 / 批量写盘在跑：别抢磁盘，稍后再来
            handler.removeCallbacks(coverRetry);
            handler.postDelayed(coverRetry, 1500);
            return;
        }
        final List<SearchIndex.Entry> batch = new ArrayList<SearchIndex.Entry>();
        while (!coverQueue.isEmpty() && batch.size() < COVER_BATCH) {
            batch.add(coverQueue.poll());
        }
        coverRunning = true;
        final int gen = metaGen;
        META_POOL.execute(new Runnable() {
            @Override
            public void run() {
                // 一个元素就是一条「docId → 位图」结果（两者必须成对，不能拆成两个列表并发写）
                final List<Object[]> hits = Collections.synchronizedList(new ArrayList<Object[]>());
                try {
                    final Storage st = host.repo.openStorage();
                    Net.map(batch, Net.READ_THREADS, null,
                            new Net.Work<SearchIndex.Entry, Object>() {
                                @Override
                                public Object run(SearchIndex.Entry e) {
                                    if (gen != metaGen) {
                                        return null;
                                    }
                                    // 1) 先看落盘缓存：命中时只读一个本地 15KB 小图，
                                    //    完全不碰 SAF —— 这就是冷启动秒出封面的关键。
                                    Bitmap bmp = CoverCache.load(host, e.file);
                                    if (bmp == null) {
                                        // 2) 内嵌封面优先，没有再退目录封面（cover.jpg / folder.jpg…）——
                                        //    与扫描阶段判定「有无封面」的口径一致，否则靠目录封面的行永远空白。
                                        byte[] cv = readCoverArt(st, e.file);
                                        if (cv == null || cv.length == 0) {
                                            cv = FolderCover.read(host, st, e.file);
                                        }
                                        bmp = decodeCover(cv);
                                        if (bmp != null && cv != null && cv.length > 0) {
                                            // 顺手补进缓存，下次重进直接命中
                                            CoverCache.saveBitmap(host, e.file, bmp);
                                        }
                                    }
                                    if (bmp != null) {
                                        hits.add(new Object[]{e.docId, bmp});
                                    }
                                    return bmp;
                                }
                            });
                } catch (Throwable ignored) {
                    // 目录掉线之类：这一批放弃，下次滚动还会再试
                }
                final List<Object[]> rows = hits;
                handler.post(new Runnable() {
                    @Override
                    public void run() {
                        coverRunning = false;
                        if (gen != metaGen) {
                            return; // 期间 reload 过：结果属于旧列表，直接丢
                        }
                        for (Object[] row : rows) {
                            coverPending.remove((String) row[0]);
                            coverCache.put((String) row[0], (Bitmap) row[1]);
                        }
                        for (SearchIndex.Entry e : batch) {
                            coverPending.remove(e.docId);
                        }
                        adapter.notifyDataSetChanged();
                        if (!coverQueue.isEmpty()) {
                            drainCover();
                        }
                    }
                });
            }
        });
    }

    /** 可见行的时长/码率：没有就排队补。 */
    private void requestAudioInfo(SearchIndex.Entry e) {
        if (e == null || e.file == null || !e.metaLoaded) {
            return;
        }
        if (e.durationMs > 0 && e.bitrateKbps > 0) {
            return;
        }
        if (audioPending.contains(e.docId)) {
            return;
        }
        if (audioQueue.size() > 200) {
            return;
        }
        audioPending.add(e.docId);
        audioQueue.add(e);
        drainAudio();
    }

    private void drainAudio() {
        if (audioRunning || audioQueue.isEmpty()) {
            return;
        }
        if (host.isTaskBusy()) {
            handler.removeCallbacks(audioRetry);
            handler.postDelayed(audioRetry, 1500);
            return;
        }
        final List<SearchIndex.Entry> batch = new ArrayList<SearchIndex.Entry>();
        while (!audioQueue.isEmpty() && batch.size() < AUDIO_BATCH) {
            batch.add(audioQueue.poll());
        }
        audioRunning = true;
        final int gen = metaGen;
        META_POOL.execute(new Runnable() {
            @Override
            public void run() {
                final List<long[]> info = new ArrayList<long[]>();
                try {
                    Storage st = host.repo.openStorage();
                    for (SearchIndex.Entry e : batch) {
                        if (gen != metaGen) {
                            break;
                        }
                        info.add(AudioInfo.read(host.getContentResolver(), st, e.file));
                    }
                } catch (Throwable ignored) {
                    // 目录掉线之类：这一批放弃，下次滚动再试
                }
                handler.post(new Runnable() {
                    @Override
                    public void run() {
                        audioRunning = false;
                        if (gen != metaGen) {
                            return;
                        }
                        for (int i = 0; i < batch.size(); i++) {
                            SearchIndex.Entry e = batch.get(i);
                            audioPending.remove(e.docId);
                            if (i >= info.size()) {
                                continue;
                            }
                            long[] v = info.get(i);
                            if (v[0] > 0) {
                                e.durationMs = v[0];
                            }
                            if (v[1] > 0) {
                                e.bitrateKbps = (int) v[1];
                            }
                            if (e.file != null && e.file.metaCached()) {
                                e.file.cachedDurationMs = e.durationMs;
                                e.file.cachedBitrateKbps = e.bitrateKbps;
                            }
                        }
                        adapter.notifyDataSetChanged();
                        if (!audioQueue.isEmpty()) {
                            drainAudio();
                        }
                    }
                });
            }
        });
    }

    // ------------------------------------------------------------------
    // 排序 / 多选
    // ------------------------------------------------------------------
    /**
     * 排序对话框。入口在顶栏右上角（{@code MainActivity.renderHeader()}），
     * 所以必须是 public；库页内的排序 chip 已在 v0.1.74 移除。
     */
    public void showSortDialog() {
        String[] items = new String[SORT_LABELS.length];
        for (int i = 0; i < items.length; i++) {
            items[i] = SORT_LABELS[i] + (i == sortKey ? "（当前）" : "");
        }
        new UiKit.Builder(getContext())
                .setTitle("排序方式")
                .setSingleChoiceItems(items, sortKey,
                        new android.content.DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(android.content.DialogInterface d, int which) {
                                sortKey = which;
                                host.repo.setInt("browse_sort", sortKey);
                                syncChips();
                                applyFilter();
                                d.dismiss();
                            }
                        })
                .setNeutralButton(sortDesc ? "改为升序" : "改为降序",
                        new android.content.DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(android.content.DialogInterface d, int which) {
                                sortDesc = !sortDesc;
                                host.repo.setBool("browse_desc", sortDesc);
                                syncChips();
                                applyFilter();
                            }
                        })
                .setNegativeButton("关闭", null)
                .show();
    }

    private void syncChips() {
        for (int i = 0; i < filterChips.length; i++) {
            UiKit.setChip(filterChips[i], filter == i);
        }
    }

    private void setSelectMode(boolean on) {
        selectMode = on;
        if (!on) {
            selected.clear();
            rangeDragging = false;
            rangeAnchor = -1;
            rangeLast = -1;
        }
        batchBar.setVisibility(on ? VISIBLE : GONE);
        if (batchFab != null) {
            batchFab.setVisibility(on ? VISIBLE : GONE);
        }
        refreshSelectionUi();
        adapter.notifyDataSetChanged();
    }

    private void toggleSelect(SearchIndex.Entry e) {
        if (selected.contains(e.docId)) {
            selected.remove(e.docId);
        } else {
            selected.add(e.docId);
        }
        refreshSelectionUi();
        adapter.notifyDataSetChanged();
    }

    /**
     * 把「锚点 → pos」整段加入选择（只增不减）。
     *
     * <p>只增不减是刻意的：拖过去再拖回来时，如果按「区间取反」实现，手指
     * 来回抖一下就会把中间几行反复选中/取消，最后剩下一堆不连续的洞。
     * 要取消某一行，抬手后点一下那行即可。
     */
    private void extendRange(int pos) {
        if (!selectMode || rangeAnchor < 0 || shown.isEmpty()) {
            return;
        }
        int from = Math.max(0, Math.min(rangeAnchor, pos));
        int to = Math.min(shown.size() - 1, Math.max(rangeAnchor, pos));
        boolean changed = false;
        for (int i = from; i <= to; i++) {
            if (selected.add(shown.get(i).docId)) {
                changed = true;
            }
        }
        rangeLast = pos;
        if (changed) {
            refreshSelectionUi();
            adapter.notifyDataSetChanged();
        }
    }

    private void refreshSelectionUi() {
        // 顶部一行就是「已选择 N 项 / 取消全选 / 关闭」
        batchCount.setText("已选择 " + selected.size() + " 项");
        if (batchSelectAll != null) {
            boolean all = !shown.isEmpty() && selected.size() >= shown.size();
            batchSelectAll.setText(all ? "取消全选" : "全选");
        }
        updateCountText();
    }

    // ------------------------------------------------------------------
    // 下拉刷新指示器
    // ------------------------------------------------------------------

    /** 跟手更新：透明度随下拉距离增加、箭头随距离旋转，过半提示「松手刷新」。 */
    private void showPullHint(float dist, int threshold) {
        if (pullPill == null) {
            return;
        }
        if (pullPill.getVisibility() != View.VISIBLE) {
            pullPill.setVisibility(View.VISIBLE);
        }
        pullPill.setAlpha(Math.min(1f, dist / threshold));
        pullPill.setTranslationY(Math.min(dist * 0.35f, UiKit.dp(getContext(), 64)));
        if (pullArrow != null) {
            pullArrow.setRotation(dist * 2f);
        }
        if (pullLabel != null) {
            pullLabel.setText(dist >= threshold ? "松手刷新" : "下拉刷新");
        }
    }

    private void hidePullHint() {
        if (pullPill == null || pullRefreshing) {
            return;
        }
        pullPill.setVisibility(View.GONE);
        pullPill.setAlpha(0f);
        pullPill.setTranslationY(0f);
        if (pullArrow != null) {
            pullArrow.setRotation(0f);
        }
    }

    /** 触发刷新：指示器固定在顶部并持续旋转，扫描任务结束后收起。 */
    private void startPullRefresh() {
        if (pullRefreshing) {
            return;
        }
        pullRefreshing = true;
        if (pullPill != null) {
            pullPill.setVisibility(View.VISIBLE);
            pullPill.setAlpha(1f);
            pullPill.setTranslationY(UiKit.dp(getContext(), 8));
        }
        if (pullLabel != null) {
            pullLabel.setText("刷新中…");
        }
        if (pullArrow != null) {
            if (pullSpin != null) {
                pullSpin.cancel();
            }
            pullSpin = android.animation.ObjectAnimator.ofFloat(pullArrow, "rotation", 0f, 360f);
            pullSpin.setDuration(700);
            pullSpin.setRepeatCount(android.animation.ValueAnimator.INFINITE);
            pullSpin.setInterpolator(new android.view.animation.LinearInterpolator());
            pullSpin.start();
        }
        host.scanGroups(false);
        watchPullRefresh(0);
    }

    private void watchPullRefresh(final int tick) {
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                if (!pullRefreshing) {
                    return;
                }
                // 扫描任务结束（或 90s 兜底）就收起指示器
                if (!host.isTaskBusy() || tick > 225) {
                    finishPullRefresh();
                } else {
                    watchPullRefresh(tick + 1);
                }
            }
        }, 400);
    }

    private void finishPullRefresh() {
        pullRefreshing = false;
        if (pullSpin != null) {
            pullSpin.cancel();
            pullSpin = null;
        }
        if (pullPill != null) {
            pullPill.animate().alpha(0f).setDuration(180).withEndAction(new Runnable() {
                @Override
                public void run() {
                    if (pullPill != null) {
                        pullPill.setVisibility(View.GONE);
                    }
                }
            }).start();
        }
    }

    /**
     * 点列表行：音频打开「单曲详情」（看全部标签 + 可直接进编辑器改），其它文件看文件信息。
     *
     * <p>v0.1.51 之前这里是直接弹操作菜单，用户要「点文件名看标签详细信息」——
     * 菜单挪到行尾的 ⋮ 按钮，两者不再抢同一个入口。
     */
    private void onRowClicked(SearchIndex.Entry e) {
        if (selectMode) {
            toggleSelect(e);
            return;
        }
        if (e.file == null) {
            return;
        }
        if (e.file.audio()) {
            TrackDetailDialog.show(host, e);
        } else {
            showInfo(e.file);
        }
    }

    private List<VFile> selectedFiles() {
        List<VFile> out = new ArrayList<VFile>();
        for (SearchIndex.Entry e : shown) {
            if (selected.contains(e.docId) && e.file != null) {
                out.add(e.file);
            }
        }
        return out;
    }

    // ------------------------------------------------------------------
    // 行渲染
    // ------------------------------------------------------------------

    /**
     * ListView 复用容器（v0.1.51 起按紧凑密度改版）。
     *
     * <p>布局从左到右：勾选框 ｜ 封面 48dp（底部叠格式后缀）｜ 中间列
     * （标题 + 徽章 / 艺人 - 专辑 / 路径）｜ 右侧三行小字（时长 · 大小 · 码率）｜ ⋮ 单文件菜单。
     *
     * <p>布局要点：48dp 封面 + 标题/艺人两行 + 右侧时长/码率两行 + 尾部 36dp 菜单位。
     * 我们把码率那一行扩成「时长 / 大小 / 质量」三行，因为用户还要看文件大小。
     */
    private final class RowView extends LinearLayout {
        final CheckBox box;
        final ImageView cover;
        final TextView ext;
        final TextView title;
        final TextView sub;
        final TextView meta;
        final LinearLayout badges;
        final TextView info1;
        final TextView info2;
        final TextView info3;
        final TextView more;

        RowView(Context ctx) {
            super(ctx);
            setOrientation(HORIZONTAL);
            setGravity(Gravity.CENTER_VERTICAL);
            setBackground(new GradientWrap());
            int pad = UiKit.dp(ctx, 10);
            setPadding(pad, pad, pad, pad);

            box = UiKit.checkbox(ctx, "", false);
            box.setVisibility(GONE);
            LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            blp.setMargins(0, 0, UiKit.dp(ctx, 6), 0);
            addView(box, blp);

            // ---- 封面：48dp 方块，底部一条渐变上叠格式后缀（MP3 / FLAC …）----
            int coverSize = UiKit.dp(ctx, 48);
            FrameLayout coverWrap = new FrameLayout(ctx);
            android.graphics.drawable.GradientDrawable coverBg =
                    new android.graphics.drawable.GradientDrawable();
            coverBg.setColor(UiKit.subColor());
            coverBg.setAlpha(45);
            coverBg.setCornerRadius(UiKit.dp(ctx, 6));
            coverWrap.setBackground(coverBg);
            cover = new ImageView(ctx);
            cover.setScaleType(ImageView.ScaleType.CENTER_CROP);
            coverWrap.addView(cover, new FrameLayout.LayoutParams(
                    coverSize, coverSize));
            ext = new TextView(ctx);
            ext.setTextSize(8);
            ext.setTextColor(Color.WHITE);
            ext.setGravity(Gravity.CENTER);
            FrameLayout.LayoutParams elp = new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT);
            elp.gravity = Gravity.BOTTOM;
            coverWrap.addView(ext, elp);
            LinearLayout.LayoutParams cwl = new LinearLayout.LayoutParams(
                    coverSize, coverSize);
            cwl.setMargins(0, 0, UiKit.dp(ctx, 10), 0);
            addView(coverWrap, cwl);

            // ---- 中间列：标题 + 徽章 / 艺人-专辑 / 路径 ----
            LinearLayout col = UiKit.vertical(ctx);
            addView(col, new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f));

            LinearLayout titleRow = UiKit.horizontal(ctx);
            titleRow.setGravity(Gravity.CENTER_VERTICAL);
            title = UiKit.text(ctx, "", 14.5f, UiKit.textColor(), false);
            // 三行都锁成单行：标签是逐行「长出来」的，行高一旦随内容变化，
            // 滚动中列表就会一格一格地跳（这是「下方抖动」的一半原因）。
            title.setSingleLine(true);
            title.setEllipsize(android.text.TextUtils.TruncateAt.END);
            titleRow.addView(title, new LinearLayout.LayoutParams(0,
                    LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
            badges = UiKit.horizontal(ctx);
            titleRow.addView(badges);
            col.addView(titleRow);

            sub = UiKit.caption(ctx, "");
            sub.setSingleLine(true);
            sub.setEllipsize(android.text.TextUtils.TruncateAt.END);
            UiKit.margin(sub, 0, 2, 0, 0);
            col.addView(sub);

            meta = UiKit.text(ctx, "", 11, UiKit.subColor(), false);
            meta.setSingleLine(true);
            meta.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
            col.addView(meta);

            // ---- 右侧三行小字：时长 / 大小 / 码率（质量）----
            LinearLayout info = UiKit.vertical(ctx);
            info.setGravity(Gravity.END);
            info1 = infoLine(ctx);
            info2 = infoLine(ctx);
            info3 = infoLine(ctx);
            info.addView(info1);
            info.addView(info2);
            info.addView(info3);
            LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT);
            ilp.setMargins(UiKit.dp(ctx, 8), 0, 0, 0);
            addView(info, ilp);

            // ---- 最右 ⋮：单文件选项入口 ----
            // 触摸区域必须够大：原来是 wrap_content + 只加 8dp 左内边距，
            // 实际可点区域大约 30×26dp（远小于 48dp 的建议值），所以「半天点不出来」。
            more = new TextView(ctx);
            more.setText("\u22EE");
            more.setTextSize(20);
            more.setTextColor(UiKit.subColor());
            more.setGravity(Gravity.CENTER);
            more.setPadding(0, 0, 0, 0);
            int touch = UiKit.dp(ctx, 44);
            more.setLayoutParams(new LinearLayout.LayoutParams(touch, touch));
            // 点按反馈：手指落点能看见，才知道「点到了」
            if (android.os.Build.VERSION.SDK_INT >= 21) {
                android.graphics.drawable.GradientDrawable mask =
                        new android.graphics.drawable.GradientDrawable();
                mask.setColor(UiKit.primarySoft());
                mask.setCornerRadius(UiKit.dp(ctx, 22));
                more.setBackground(new android.graphics.drawable.RippleDrawable(
                        android.content.res.ColorStateList.valueOf(UiKit.subColor()),
                        null, mask));
            }
            more.setContentDescription("更多操作");
            // 不加这两行，ListView 会因为「行里有可聚焦子控件」而让整行的点击失效
            more.setFocusable(false);
            more.setFocusableInTouchMode(false);
            addView(more);
        }

        /** 右侧信息行：10.5sp 小字、右对齐、单行。 */
        private TextView infoLine(Context ctx) {
            TextView t = UiKit.text(ctx, "", 10.5f, UiKit.subColor(), false);
            t.setSingleLine(true);
            t.setGravity(Gravity.END);
            return t;
        }
    }

    private final class RowAdapter extends BaseAdapter {
        @Override
        public int getCount() {
            return shown.size();
        }

        @Override
        public Object getItem(int position) {
            return shown.get(position);
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            Context ctx = parent.getContext();
            final SearchIndex.Entry e = shown.get(position);
            RowView row;
            if (convertView instanceof RowView) {
                row = (RowView) convertView;
            } else {
                row = new RowView(ctx);
                UiKit.margin(row, 0, 0, 0, 3);
            }

            // 滚到哪读到哪：先排队，读完会 notifyDataSetChanged 自动补上
            requestMeta(e);
            // 标签已在（缓存直填）的条目不会走 requestMeta，封面与时长要单独补
            requestCover(e);
            requestAudioInfo(e);

            String title = e.displayTitle();
            row.title.setText(highlight(title, e));
            String sub = e.displaySub();
            row.sub.setText(sub.isEmpty() ? (e.metaLoaded ? "—" : "读取标签…")
                    : highlight(sub, e));
            row.meta.setText(e.relPath + " · " + TextUtil.formatSize(e.size));

            // 封面：缓存里有就用，没有就留占位底色（meta 读完会 notifyDataSetChanged 补上）
            Bitmap bmp = coverCache.get(e.docId);
            if (bmp != null) {
                row.cover.setImageBitmap(bmp);
            } else {
                row.cover.setImageDrawable(null);
            }
            String suffix = e.file == null ? "" : e.file.ext();
            row.ext.setText(suffix.isEmpty() ? ""
                    : suffix.substring(1).toUpperCase(Locale.US));

            setInfo(row.info1, TrackInfo.duration(e.durationMs));
            setInfo(row.info2, TextUtil.formatSize(e.size));
            setInfo(row.info3, TrackInfo.bitrate(e.bitrateKbps));

            // 最右 ⋮：单文件选项入口（与点整行看详情是两回事，所以单独接点击）
            row.more.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    if (e.file != null) {
                        showMenu(e.file);
                    }
                }
            });

            row.badges.removeAllViews();
            if (e.metaLoaded) {
                if (!e.hasCover) {
                    addBadge(row.badges, "无封面", UiKit.warnColor());
                }
                if (!e.hasLyrics) {
                    addBadge(row.badges, "无歌词", UiKit.subColor());
                }
                if (!e.tagComplete()) {
                    addBadge(row.badges, "待补", UiKit.primary());
                }
            }

            row.box.setVisibility(selectMode ? VISIBLE : GONE);
            row.box.setOnCheckedChangeListener(null);
            row.box.setChecked(selected.contains(e.docId));
            row.box.setOnCheckedChangeListener(
                    new android.widget.CompoundButton.OnCheckedChangeListener() {
                        @Override
                        public void onCheckedChanged(android.widget.CompoundButton b,
                                                     boolean checked) {
                            if (checked) {
                                selected.add(e.docId);
                            } else {
                                selected.remove(e.docId);
                            }
                            refreshSelectionUi();
                        }
                    });
            return row;
        }
    }

    /**
     * 右侧信息行：空值整行隐藏。
     *
     * <p>时长 / 码率经常取不到（格式不支持、文件损坏），如果不隐藏就会留下一两道空白，
     * 看起来像「应用把数据藏了」。隐藏后剩余行仍在 48dp 封面决定的行高内，不会抖动。
     */
    private static void setInfo(TextView t, String value) {
        if (value == null || value.isEmpty()) {
            t.setVisibility(View.GONE);
            return;
        }
        t.setVisibility(View.VISIBLE);
        t.setText(value);
    }

    private void addBadge(LinearLayout row, String text, int color) {        TextView b = UiKit.badge(getContext(), text, color);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.setMargins(UiKit.dp(getContext(), 4), 0, 0, 0);
        row.addView(b, lp);
    }

    /** 命中高亮：按原始词（大小写不敏感）加粗变蓝，避免归一后位置对不上。 */
    private CharSequence highlight(String text, SearchIndex.Entry e) {
        if (text == null || text.isEmpty() || query.raw.isEmpty()) {
            return text == null ? "" : text;
        }
        String lower = text.toLowerCase(Locale.ROOT);
        SpannableString span = new SpannableString(text);
        boolean any = false;
        for (String raw : query.raw) {
            String term = raw.toLowerCase(Locale.ROOT);
            if (term.isEmpty()) {
                continue;
            }
            int from = 0;
            while (true) {
                int idx = lower.indexOf(term, from);
                if (idx < 0) {
                    break;
                }
                span.setSpan(new ForegroundColorSpan(UiKit.primary()), idx, idx + term.length(),
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                span.setSpan(new StyleSpan(android.graphics.Typeface.BOLD), idx,
                        idx + term.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                any = true;
                from = idx + term.length();
            }
        }
        return any ? span : text;
    }

    private static final class GradientWrap extends android.graphics.drawable.GradientDrawable {
        {
            setColor(UiKit.cardColor());
            setCornerRadius(12);
        }

        GradientWrap() {
        }
    }

    // ------------------------------------------------------------------
    // 单文件菜单 / 查重
    // ------------------------------------------------------------------

    private void showMenu(final VFile f) {
        if (!f.audio()) {
            showInfo(f);
            return;
        }
        new UiKit.Builder(getContext())
                .setTitle(f.name)
                .setItems(new String[]{"编辑标签…", "歌词工具箱…", "清理标签文本",
                                "手动归类到歌手…", "获取歌词", "查看信息"},
                        new android.content.DialogInterface.OnClickListener() {
                            @Override
                            public void onClick(android.content.DialogInterface d, int which) {
                                if (which == 0) {
                                    TagEditorDialog.show(host, f);
                                } else if (which == 1) {
                                    LyricsToolDialog.show(host, f);
                                } else if (which == 2) {
                                    List<VFile> one = new ArrayList<VFile>();
                                    one.add(f);
                                    BatchActions.tidyTags(host, one);
                                } else if (which == 3) {
                                    manualClassify(f);
                                } else if (which == 4) {
                                    fetchOneLyrics(f);
                                } else {
                                    showInfo(f);
                                }
                            }
                        })
                .setNegativeButton("关闭", null)
                .show();
    }

    private void showInfo(VFile f) {
        StringBuilder sb = new StringBuilder();
        sb.append("文件名：").append(f.name).append('\n');
        sb.append("路径：").append(f.pathAfterRoot()).append('\n');
        sb.append("大小：").append(TextUtil.formatSize(f.size)).append('\n');
        sb.append("格式：").append(f.ext().isEmpty() ? "未知" : f.ext()).append('\n');
        sb.append("修改时间：").append(android.text.format.DateFormat.format(
                "yyyy-MM-dd HH:mm", f.lastModified));
        new UiKit.Builder(getContext())
                .setTitle("文件信息")
                .setMessage(sb.toString())
                .setPositiveButton("确定", null)
                .show();
    }

    private void fetchOneLyrics(final VFile f) {
        host.runTask("获取歌词", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                List<VFile> one = new ArrayList<VFile>();
                one.add(f);
                Lyrics.FetchResult res = Lyrics.fetchMatches(st, host.getContentResolver(),
                        one, true, false,
                        NameWeight.fromPercent(host.repo.intVal("fn_weight",
                                NameWeight.DEFAULT_PERCENT)),
                        null, host.progressCallback(), host.cancelToken(), host, null);
                return res.matches.isEmpty() ? null : res.matches.get(0);
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                if (result == null) {
                    host.message("没有找到歌词",
                            "四个歌词源都没有返回可用结果，可以到整理页批量再试一次。");
                    return;
                }
                final Lyrics.Match m = (Lyrics.Match) result;
                LyricsPreview.showSingle(host, m, new LyricsPreview.OnConfirm() {
                    @Override
                    public void confirmed(List<Lyrics.Match> selected) {
                        host.runTask("写入歌词", new Tasks.Job() {
                            @Override
                            public Object run() throws Exception {
                                Storage st = host.safeStorage();
                                return Lyrics.writeMatches(st, host.getContentResolver(), host,
                                        selected, true, host.repo.bool("lrc_embed", true),
                                        host.progressCallback(), host.cancelToken(), host, null,
                                        host.batchQueue("lyrics"));
                            }
                        }, new Tasks.Callback() {
                            @Override
                            public void done(Object r, Exception err) {
                                if (err != null) {
                                    host.fail(err);
                                    return;
                                }
                                int[] n = (int[]) r;
                                host.toast("歌词写入 " + n[0] + " 首");
                                // 歌词不改文件数量：只刷新这一首，不重扫整个目录
                                host.refreshBrowseTagOnly(
                                        java.util.Collections.singletonList(f));
                            }
                        });
                    }
                });
            }
        });
    }

    private void manualClassify(final VFile f) {
        final EditText input = UiKit.input(getContext(), "歌手名（会移动到根目录下该文件夹）");
        new UiKit.Builder(getContext())
                .setTitle("手动归类")
                .setView(input)
                .setPositiveButton("移动", new android.content.DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(android.content.DialogInterface d, int which) {
                        final String artist = input.getText().toString().trim();
                        if (artist.isEmpty()) {
                            host.toast("歌手名不能为空");
                            return;
                        }
                        host.runTask("手动归类", new Tasks.Job() {
                            @Override
                            public Object run() throws Exception {
                                Storage st = host.safeStorage();
                                VFile dir = Scanner.dirOf(st, host.root(), f);
                                List<VFile> group = new ArrayList<VFile>();
                                for (VFile c : st.children(dir)) {
                                    if (!c.dir && c.music()
                                            && c.stem().equalsIgnoreCase(f.stem())) {
                                        group.add(c);
                                    }
                                }
                                VFile target = st.ensureDir(host.root(),
                                        Organizer.simplifyArtistFolder(artist));
                                int moved = 0;
                                for (VFile m : group) {
                                    String name = m.name;
                                    if (st.findChild(target, name) != null) {
                                        int i = 1;
                                        while (st.findChild(target,
                                                m.stem() + "_" + i + m.ext()) != null) {
                                            i++;
                                        }
                                        name = m.stem() + "_" + i + m.ext();
                                        st.rename(m, name);
                                    }
                                    if (st.move(m, target)) {
                                        moved++;
                                    }
                                }
                                return moved;
                            }
                        }, new Tasks.Callback() {
                            @Override
                            public void done(Object result, Exception error) {
                                if (error != null) {
                                    host.fail(error);
                                    return;
                                }
                                host.log("手动归类完成：" + artist + " ← " + result + " 个文件",
                                        "success");
                                host.toast("已移动 " + result + " 个文件");
                                host.refreshBrowseAfterChange();
                            }
                        });
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    public void startDuplicateScan() {
        findDuplicates();
    }

    /** 文件名查重：自己递归扫目录树（不依赖上次扫描结果）。 */
    private void findDuplicates() {
        host.runTask("文件名查重", new Tasks.Job() {
            @Override
            public Object run() throws Exception {
                Storage st = host.safeStorage();
                List<VFile> files = Scanner.walkMusic(st, host.root(), true,
                        host.progressCallback(), host.cancelToken());
                List<VFile> audio = new ArrayList<VFile>();
                for (VFile f : files) {
                    if (f.audio()) {
                        audio.add(f);
                    }
                }
                return com.dsh.musicorganizer.core.Duplicates.find(audio, host.root().docId,
                        host.progressCallback(), host.cancelToken());
            }
        }, new Tasks.Callback() {
            @Override
            public void done(Object result, Exception error) {
                if (error != null) {
                    host.fail(error);
                    return;
                }
                @SuppressWarnings("unchecked")
                List<com.dsh.musicorganizer.core.Duplicates.Group> groups =
                        (List<com.dsh.musicorganizer.core.Duplicates.Group>) result;
                if (host.lastTaskStopped()) {
                    host.toast("已停止查重");
                    return;
                }
                if (groups.isEmpty()) {
                    host.message("没有发现相似文件",
                            "扫描完整个目录树，没有文件名相似度 ≥ 90% 的文件。");
                    return;
                }
                host.log("文件名查重：" + com.dsh.musicorganizer.core.Duplicates.summary(groups),
                        "info");
                DuplicateDialog.show(host, groups);
            }
        });
    }
}
