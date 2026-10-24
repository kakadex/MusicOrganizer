package com.dsh.musicorganizer.net;

import com.dsh.musicorganizer.core.AppUpdate;

import java.util.HashMap;
import java.util.Map;

/**
 * 检查 GitHub Release 上的最新版本（零依赖，直接用 Http + core.Json）。
 *
 * <p>几个刻意的取舍：
 * <ul>
 *   <li><b>只用匿名 API</b>：不带 token，一小时 60 次够用（自动检查每天最多一次）。
 *       也因此绝不能在「批量任务」里反复调用，否则会撞限流。</li>
 *   <li><b>不猜下载地址</b>：APK 直链优先取 Release 里的 assets（文件名带中文，
 *       自己拼百分号编码容易拼错），没有资产才退回发布页。</li>
 *   <li><b>失败一律给可读原因</b>：连不上 / 被限流 / 返回的不是 JSON，文案不同，
 *       用户一看就知道该改地址还是等一会。</li>
 * </ul>
 */
public final class UpdateClient {

    /** 与 {@link Endpoints} 里登记的源标识一致。 */
    public static final String SOURCE = "update";

    /** 国内镜像源（Gitee）：更新检查首选它，GitHub 只当兜底。 */
    public static final String GITEE = "gitee";

    /** 最新版本 API */
    public static final int EP_API = 0;
    /** Release 列表页 */
    public static final int EP_RELEASES = 1;
    /** 仓库主页 */
    public static final int EP_REPO = 2;
    /** 纯文本版本清单（Gitee 用它当主通道，GitHub 用它当兜底） */
    public static final int EP_GH_MANIFEST = 3;
    public static final int EP_GITEE_MANIFEST = 0;
    public static final int EP_GITEE_RELEASES = 1;
    public static final int EP_GITEE_REPO = 2;

    /** 检查更新的超时（比批量任务宽松一点：只发一次请求，值得多等）。 */
    private static final int TIMEOUT_MS = 8000;

    private UpdateClient() {
    }

    /** 检查结果：成功时 {@link #release} 非空，失败时 {@link #error} 是给人看的原因。 */
    public static final class Result {
        public final AppUpdate.Release release;
        public final String error;

        Result(AppUpdate.Release release, String error) {
            this.release = release;
            this.error = error;
        }

        public boolean ok() {
            return release != null;
        }
    }

    /** 同步请求（必须在后台线程调用）。 */
    public static Result fetchLatest() {
        // ① 国内优先：Gitee 的 dist/latest.txt（静态文件，不要 token、不限速）
        Result r = fromManifest(GITEE, "Gitee");
        if (r.ok()) {
            return r;
        }
        String firstError = r.error;
        // ② 兜底一：GitHub raw 上的同一份清单（不走 API，就没有 60 次/小时的限制）
        r = fromManifest(SOURCE, "GitHub");
        if (r.ok()) {
            return r;
        }
        // ③ 兜底二：原来的 GitHub Release API（有 Release 资产时它的信息最全）
        r = fromApi();
        if (r.ok()) {
            return r;
        }
        // 三条都失败：把前两条的原因合成一句，附上 API 那条，方便判断是断网还是被墙
        String apiError = r.error == null ? "" : r.error;
        StringBuilder sb = new StringBuilder();
        if (firstError != null && !firstError.isEmpty()) {
            sb.append(firstError);
        }
        if (!apiError.isEmpty()) {
            if (sb.length() > 0) {
                sb.append("\n");
            }
            sb.append(apiError);
        }
        return new Result(null, sb.length() == 0 ? "检查更新失败，请稍后再试" : sb.toString());
    }

    /**
     * 从「版本清单」纯文本接口取最新版本。
     *
     * @param source 源标识（{@code gitee} / {@code update}）
     * @param name   给人看的名字（写进错误提示）
     */
    private static Result fromManifest(String source, String name) {
        if (!Endpoints.enabled(source)) {
            return new Result(null, name + " 更新源已在「数据源设置」里停用");
        }
        String url = Endpoints.url(source, source.equals(GITEE) ? EP_GITEE_MANIFEST : EP_GH_MANIFEST);
        if (url == null || url.trim().isEmpty()) {
            return new Result(null, name + " 还没有配置版本清单地址");
        }
        String text = Http.getText(url, new HashMap<String, String>(),
                new HashMap<String, String>(), TIMEOUT_MS);
        if (text == null) {
            String why = Http.lastError();
            return new Result(null, "连不上 " + name
                    + (why == null || why.isEmpty() ? "" : "（" + why + "）"));
        }
        AppUpdate.Release rel = AppUpdate.parseManifest(text, url);
        if (rel == null) {
            String hint = text.trim().startsWith("<")
                    ? "返回的是网页（可能被代理拦了，或仓库里还没有 dist/latest.txt）"
                    : "返回内容不是版本清单格式";
            return new Result(null, name + "：" + hint);
        }
        return new Result(rel, null);
    }

    /** 原来的 GitHub Release API 通道（信息最全：带 Release 说明与资产直链）。 */
    private static Result fromApi() {
        if (!Endpoints.enabled(SOURCE)) {
            return new Result(null, "「" + label() + "」已在数据源设置里停用，"
                    + "到「整理 → 数据源设置」里重新勾选即可");
        }
        String url = Endpoints.url(SOURCE, EP_API);
        if (url == null || url.trim().isEmpty()) {
            return new Result(null, "还没有配置更新接口地址");
        }
        Map<String, String> headers = new HashMap<String, String>();
        headers.put("Accept", "application/vnd.github+json");
        headers.put("X-GitHub-Api-Version", "2022-11-28");

        String text = Http.getText(url, new HashMap<String, String>(), headers, TIMEOUT_MS);
        if (text == null) {
            String why = Http.lastError();
            return new Result(null, "连不上 GitHub"
                    + (why == null || why.isEmpty() ? "" : "（" + why + "）")
                    + "\n可以在「数据源设置 → 修改地址」里换成镜像地址，或过一会儿再试");
        }
        AppUpdate.Release r = AppUpdate.parseRelease(text);
        if (r == null) {
            String hint = text.trim().startsWith("<")
                    ? "返回的是网页而不是数据，可能被代理/加速服务拦截了"
                    : "返回内容不是 GitHub Release 格式";
            return new Result(null, hint + "（也可能是仓库还没有发布过 Release）");
        }
        return new Result(r, null);
    }

    /** 发布页地址（浏览器打开）—— 有 Gitee 就用 Gitee。 */
    public static String releasesPage() {
        String gitee = Endpoints.url(GITEE, EP_GITEE_RELEASES);
        if (gitee != null && !gitee.trim().isEmpty()) {
            return gitee;
        }
        String url = Endpoints.url(SOURCE, EP_RELEASES);
        return url == null ? "" : url;
    }

    /** 仓库主页地址（国内优先 Gitee）。 */
    public static String repoPage() {
        String gitee = Endpoints.url(GITEE, EP_GITEE_REPO);
        if (gitee != null && !gitee.trim().isEmpty()) {
            return gitee;
        }
        String url = Endpoints.url(SOURCE, EP_REPO);
        return url == null ? "" : url;
    }

    private static String label() {
        Endpoints.Source s = Endpoints.find(SOURCE);
        return s == null ? "GitHub 更新" : s.label;
    }
}
