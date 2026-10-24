package com.dsh.musicorganizer.ui;

/**
 * 「已获取部分」预览提供者 —— 长任务在跑的时候注册到 {@link TaskCenter}，
 * 用户一按暂停，底部面板就出现「预览已获取 N 条」，点了就展示这份半成品。
 *
 * <p>为什么由发起方实现而不是任务中心自己实现：不同任务的结果类型完全不同
 * （歌词 Match / 标签 Match），预览窗与「确认后怎么写」的逻辑也只有发起方知道。
 * 任务中心只负责在暂停时把按钮露出来、把点击转过来。
 */
public interface PartialPreview {

    /** 已获取条数。会在主线程被高频调用，必须是廉价操作（读长度即可）。 */
    int count();

    /** 打开预览（主线程调用）。 */
    void show(MainActivity host);
}
