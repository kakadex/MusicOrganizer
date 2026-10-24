package com.dsh.musicorganizer.core;

/** 取消令牌（对应 Python 版 threading.Event）。 */
public interface CancelToken {

    /** 检查点：可能因为「暂停」而阻塞，返回是否已取消。 */
    boolean isCancelled();

    /**
     * 不阻塞的取消状态查询。
     *
     * <p>并发批量任务的调度线程若用 {@link #isCancelled()}，会被暂停检查点卡住，
     * 导致「停止」要等当前请求超时才生效；这个版本只读状态、不等待。
     * 默认退化为 {@link #isCancelled()}，具体实现（如 TaskControl）可覆盖。
     */
    default boolean isCancelledNow() {
        return isCancelled();
    }
}
