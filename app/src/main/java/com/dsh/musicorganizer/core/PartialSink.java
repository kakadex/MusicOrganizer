package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.List;
import java.util.TreeMap;

/**
 * 「边跑边收」的已完成结果缓冲区 —— 支撑「暂停时预览已获取部分」。
 *
 * <p><b>为什么需要它</b>：匹配阶段的条目原本是整批跑完后由 {@code Net.map} 一次性返回的。
 * 用户按下暂停时，工作线程阻塞在检查点上，已经匹配好的几十条结果还躺在工作线程的局部变量里，
 * UI 一个都拿不到，只能干等。这里让每条结果一产出就放进线程安全的容器，UI 随时能取一份快照去看。
 *
 * <p><b>快照语义</b>：{@link #snapshot()} 返回独立副本，且<b>按序号归位</b>——并发下各文件
 * 谁先完成谁先 {@link #add}，但预览里仍按文件列表的原始顺序展示，不会一会儿东一会儿西。
 * 预览里勾选/取消勾选只影响副本里的引用对象（元素本身各自独立，不会被工作线程再改）。
 *
 * <p>纯 Java，不依赖 Android，可离线回归测试。
 */
public final class PartialSink<T> {

    /** 按序号归位；未指定序号（旧调用）时用自增序号兜底，保证稳定排序。 */
    private final TreeMap<Integer, T> items = new TreeMap<Integer, T>();
    private int fallbackSeq = 0;

    /** 收一条已完成的结果（null 忽略，按完成顺序追加）。工作线程并发调用安全。 */
    public void add(T item) {
        if (item == null) {
            return;
        }
        synchronized (this) {
            items.put(fallbackSeq++, item);
        }
    }

    /** 收一条已完成的结果，并指定它在文件列表中的原始序号（预览按此排序）。 */
    public void add(int index, T item) {
        if (item == null) {
            return;
        }
        synchronized (this) {
            // 同一序号重复投递时取最后一次（正常不会发生；防御性处理）
            items.put(index, item);
        }
    }

    /** 已获取条数；暂停时面板按钮用它显示数量。 */
    public int size() {
        synchronized (this) {
            return items.size();
        }
    }

    public boolean isEmpty() {
        return size() == 0;
    }

    /** 取快照（独立副本，按序号升序 = 文件列表顺序）。 */
    public List<T> snapshot() {
        synchronized (this) {
            return new ArrayList<T>(items.values());
        }
    }

    public void clear() {
        synchronized (this) {
            items.clear();
            fallbackSeq = 0;
        }
    }
}
