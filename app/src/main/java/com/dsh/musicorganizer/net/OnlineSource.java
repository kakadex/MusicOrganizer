package com.dsh.musicorganizer.net;

import java.util.List;

/**
 * 一个「在线元数据源」的统一契约（v0.1.80）。
 *
 * <p>以前所有源都挤在 {@code Sources} 的 if-else 里：加一家要改三处、还没法说明
 * 「这家支不支持歌词 / 封面」。这里把它拆成「一个源一个实现 + 注册表」，
 * 新增源只需要写一个类并在 {@link SourceRegistry} 登记，聚合流程一行都不用动。
 *
 * <p>能力位（tags / lyrics / cover）只是**声明**，用于界面提示与将来的按能力挑选；
 * 目前的聚合仍然按 {@code SourceRank} 的顺序调用 {@link #search}。
 */
public interface OnlineSource {

    /** 与 {@code Endpoints} 里登记的 key 一致（如 {@code netease}）。 */
    String key();

    /** 给人看的名字（如「网易云」）。 */
    String label();

    /** 能否提供标签字段（标题/歌手/专辑/年份/音轨/流派）。 */
    boolean supportsTags();

    /** 能否提供歌词。 */
    boolean supportsLyrics();

    /** 能否提供封面地址。 */
    boolean supportsCover();

    /**
     * 按查询上下文搜一遍。
     *
     * @param q      查询上下文（文件名候选、已有标签、时长、权重）
     * @param client MusicBrainz 客户端（只有该源需要，其余可为 null）
     * @return 候选列表；查不到返回空列表，不允许返回 null
     */
    List<Sources.Candidate> search(Sources.Query q, MbClient client) throws Exception;
}
