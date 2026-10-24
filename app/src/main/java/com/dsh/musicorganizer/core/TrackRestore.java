package com.dsh.musicorganizer.core;

/**
 * 把 {@link VFile} 上的「已读过的展示信息」整体回填到列表条目（v0.1.52）。
 *
 * <p>为什么要有这个类：库页重建索引（{@code reload()}）时，如果文件已经有缓存，
 * 会走「缓存直填」这条路，免得补一首歌就把整个目录的标签重读一遍。
 * 但缓存里的东西是**一组**——标签、有无封面、有无歌词、时长、码率，
 * 少回填一个，界面上就少一块：
 * <ul>
 *   <li>只填标签 → 列表右侧的「时长 · 大小 · 质量」集体消失；</li>
 *   <li>不回填「有封面」→ 封面补读队列根本不会去读，封面永远空白。</li>
 * </ul>
 *
 * <p>这几个字段分散在 {@code SearchIndex.Entry} 与 {@code VFile} 两处，
 * 容易只改一半，所以集中在这里做，并且可以进纯 JVM 回归。
 */
public final class TrackRestore {

    private TrackRestore() {
    }

    /**
     * 用文件缓存回填条目。
     *
     * @param e      列表条目
     * @param f      源文件（缓存挂在这上面）
     * @param hasLrc 是否找到同名 {@code .lrc}（外部判断，见 {@code BrowsePage.reload}）
     * @return 是否真的用缓存填了（{@code false} 表示没有缓存，调用方应当去读盘）
     */
    public static boolean apply(SearchIndex.Entry e, VFile f, boolean hasLrc) {
        if (e == null || f == null || !f.metaCached()) {
            return false;
        }
        e.applyTags(f.cachedTags, f.cachedHasCover);
        e.durationMs = f.cachedDurationMs;
        e.bitrateKbps = f.cachedBitrateKbps;
        if (hasLrc) {
            e.hasLyrics = true;
        }
        return true;
    }
}
