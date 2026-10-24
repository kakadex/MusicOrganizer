package com.dsh.musicorganizer.core;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/** 同基名的音频 + 歌词文件组（对应 Python 版 TrackGroup）。 */
public final class TrackGroup {

    private static final String[] AUDIO_EXT_ORDER = {
            ".mp3", ".flac", ".m4a", ".wav", ".ogg", ".aac", ".wma", ".ape", ".opus",
    };

    public final VFile dir;
    public final String basename;
    public final List<VFile> audio = new ArrayList<VFile>();
    public final List<VFile> lyrics = new ArrayList<VFile>();

    public TrackGroup(VFile dir, String basename) {
        this.dir = dir;
        this.basename = basename;
    }

    private static int audioOrder(VFile f) {
        String ext = f.ext();
        for (int i = 0; i < AUDIO_EXT_ORDER.length; i++) {
            if (AUDIO_EXT_ORDER[i].equals(ext)) {
                return i;
            }
        }
        return AUDIO_EXT_ORDER.length;
    }

    /** 音频优先（按格式权重），歌词随后 —— 原子移动顺序与 Python 版一致。 */
    public List<VFile> allFiles() {
        List<VFile> a = new ArrayList<VFile>(audio);
        List<VFile> l = new ArrayList<VFile>(lyrics);
        Collections.sort(a, new Comparator<VFile>() {
            @Override
            public int compare(VFile x, VFile y) {
                int d = audioOrder(x) - audioOrder(y);
                if (d != 0) {
                    return d;
                }
                return x.name.toLowerCase().compareTo(y.name.toLowerCase());
            }
        });
        Collections.sort(l, new Comparator<VFile>() {
            @Override
            public int compare(VFile x, VFile y) {
                return x.name.toLowerCase().compareTo(y.name.toLowerCase());
            }
        });
        List<VFile> all = new ArrayList<VFile>(a);
        all.addAll(l);
        return all;
    }

    public VFile primaryAudio() {
        List<VFile> all = allFiles();
        for (VFile f : all) {
            if (f.audio()) {
                return f;
            }
        }
        return null;
    }

    public String displayName() {
        return basename + "（" + (audio.size() + lyrics.size()) + " 个文件）";
    }
}
