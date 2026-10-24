package com.dsh.musicorganizer.core;

/** 运行日志回调。level 取 info / success / warning / error。 */
public interface Logger {

    void log(String message, String level);
}
