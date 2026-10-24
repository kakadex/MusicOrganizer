package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.List;

/**
 * 一次批量匹配里「没联网就被跳过」的明细。
 *
 * <p><b>为什么需要它</b>：批量任务会记住上批的结论（见 {@link BatchMemory}），
 * 下次遇到「上批确认查不到 / 已写入」的歌直接跳过。这个设计省掉了大量重复查询，
 * 但留下一个死角 —— 用户后来想重查那些歌时，界面只会说一句「按记忆跳过 N 首」，
 * 没有哪首歌可以被重新查询。
 *
 * <p>这里把「按记忆跳过」的那几首记下来，界面就能在提示旁边直接给一个
 * 「重新查询这 N 首」的按钮：先 {@link BatchMemory#forget(String)} 忘掉旧结论，
 * 再对这几首重跑一次。
 *
 * <p>只收集「按记忆跳过」：格式不支持重查也没用，标签已完整 / 已有 lrc 用户自己能看见，
 * 都不需要这个入口。
 */
public final class BatchSkip {

    private final List<VFile> memory = new ArrayList<VFile>();

    /** 记一首「按记忆跳过」的歌（匹配是并发的，这里同步）。 */
    public synchronized void addMemory(VFile f) {
        if (f != null) {
            memory.add(f);
        }
    }

    /** 按记忆跳过的歌（副本，调用方随便改）。 */
    public synchronized List<VFile> memoryFiles() {
        return new ArrayList<VFile>(memory);
    }

    public synchronized int memoryCount() {
        return memory.size();
    }

    public boolean hasMemorySkips() {
        return memoryCount() > 0;
    }

    /** 「按记忆跳过 12 首（上批已确认查不到或已写入）」 */
    public String note() {
        int n = memoryCount();
        return n <= 0 ? "" : "按记忆跳过 " + n + " 首（上批已确认查不到或已写入）";
    }
}
