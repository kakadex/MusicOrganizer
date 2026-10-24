package com.dsh.musicorganizer.core;

/** 进度回调（对应 Python 版 progress 回调）。 */
public interface Progress {

    void onProgress(int done, int total, String message);
}
