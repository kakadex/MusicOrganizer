package com.dsh.musicorganizer.ui;

import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.drawable.Drawable;

/**
 * 纯代码绘制的线性图标（24×24 视口，描边风格）。
 *
 * <p>项目零第三方依赖、也不放位图资源，底部导航与标题栏的齿轮都在这里用 Canvas 画。
 * 图标按 {@link Drawable#getBounds()} 自适应缩放，颜色可随时 {@link #setColor(int)} 切换
 * （导航选中/未选中只是换个颜色，不需要两套资源）。
 */
public final class NavIcon extends Drawable {

    public static final int ORGANIZE = 0;
    public static final int LIBRARY = 1;
    public static final int LOG = 2;
    public static final int GEAR = 3;
    /** 子页左上角的返回箭头。 */
    public static final int BACK = 4;
    /** 主界面右上角的排序入口。 */
    public static final int SORT = 5;

    private static final float VIEW = 24f;

    private final int kind;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();
    private final RectF oval = new RectF();

    public NavIcon(int kind, int color) {
        this.kind = kind;
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeCap(Paint.Cap.ROUND);
        paint.setStrokeJoin(Paint.Join.ROUND);
        paint.setColor(color);
    }

    public void setColor(int color) {
        if (paint.getColor() != color) {
            paint.setColor(color);
            invalidateSelf();
        }
    }

    @Override
    public void draw(Canvas canvas) {
        Rect b = getBounds();
        if (b.width() <= 0 || b.height() <= 0) {
            return;
        }
        float scale = Math.min(b.width(), b.height()) / VIEW;
        // 描边宽度按最终尺寸折算：22dp 的图标约 2dp 线宽，缩小后不会糊在一起
        float stroke = Math.max(1.2f, 1.9f * scale);
        paint.setStrokeWidth(stroke);

        int save = canvas.save();
        canvas.translate(b.exactCenterX(), b.exactCenterY());
        canvas.scale(scale, scale);
        canvas.translate(-VIEW / 2f, -VIEW / 2f);
        switch (kind) {
            case ORGANIZE:
                drawOrganize(canvas);
                break;
            case LIBRARY:
                drawLibrary(canvas);
                break;
            case LOG:
                drawLog(canvas);
                break;
            case GEAR:
                drawGear(canvas);
                break;
            case BACK:
                drawBack(canvas);
                break;
            case SORT:
                drawSort(canvas);
                break;
            default:
                break;
        }
        canvas.restoreToCount(save);
    }

    /** 整理：三条滑杆 + 旋钮（「调节」的通用语义）。 */
    private void drawOrganize(Canvas c) {
        path.reset();
        path.moveTo(3, 6);
        path.lineTo(21, 6);
        path.moveTo(3, 12);
        path.lineTo(21, 12);
        path.moveTo(3, 18);
        path.lineTo(21, 18);
        c.drawPath(path, paint);
        knob(c, 8, 6);
        knob(c, 15, 12);
        knob(c, 10, 18);
    }

    private void knob(Canvas c, float x, float y) {
        oval.set(x - 2.4f, y - 2.4f, x + 2.4f, y + 2.4f);
        c.drawOval(oval, paint);
    }

    /** 库：两行两列圆角方块，读作「一堆东西分门别类」。 */
    private void drawLibrary(Canvas c) {
        float r = 2.2f;
        oval.set(4.5f, 4.5f, 11.2f, 11.2f);
        c.drawRoundRect(oval, r, r, paint);
        oval.set(12.8f, 4.5f, 19.5f, 11.2f);
        c.drawRoundRect(oval, r, r, paint);
        oval.set(4.5f, 12.8f, 11.2f, 19.5f);
        c.drawRoundRect(oval, r, r, paint);
        oval.set(12.8f, 12.8f, 19.5f, 19.5f);
        c.drawRoundRect(oval, r, r, paint);
    }

    /** 日志：一张带横线的纸。 */
    private void drawLog(Canvas c) {
        oval.set(5.5f, 3f, 18.5f, 21f);
        c.drawRoundRect(oval, 2.4f, 2.4f, paint);
        path.reset();
        path.moveTo(9, 8.5f);
        path.lineTo(15, 8.5f);
        path.moveTo(9, 12.5f);
        path.lineTo(15, 12.5f);
        path.moveTo(9, 16.5f);
        path.lineTo(12.5f, 16.5f);
        c.drawPath(path, paint);
    }

    /** 齿轮：外环 + 8 个齿 + 中心孔。 */
    private void drawGear(Canvas c) {
        oval.set(4.2f, 4.2f, 19.8f, 19.8f);
        c.drawOval(oval, paint);
        oval.set(9.2f, 9.2f, 14.8f, 14.8f);
        c.drawOval(oval, paint);
        path.reset();
        for (int i = 0; i < 8; i++) {
            double a = Math.toRadians(i * 45);
            float cos = (float) Math.cos(a);
            float sin = (float) Math.sin(a);
            path.moveTo(12 + cos * 7.8f, 12 + sin * 7.8f);
            path.lineTo(12 + cos * 10.4f, 12 + sin * 10.4f);
        }
        c.drawPath(path, paint);
    }

    /** 返回：一根横线 + 左向箭头（←）。 */
    private void drawBack(Canvas c) {
        path.reset();
        path.moveTo(20f, 12f);
        path.lineTo(5f, 12f);
        path.moveTo(12f, 5f);
        path.lineTo(5f, 12f);
        path.lineTo(12f, 19f);
        c.drawPath(path, paint);
    }

    /** 排序：三条从长到短的横线（Lucide「sort」的线性写法）。 */
    private void drawSort(Canvas c) {
        path.reset();
        path.moveTo(21f, 6f);
        path.lineTo(3f, 6f);
        path.moveTo(15f, 12f);
        path.lineTo(3f, 12f);
        path.moveTo(9f, 18f);
        path.lineTo(3f, 18f);
        c.drawPath(path, paint);
    }

    @Override
    public void setAlpha(int alpha) {
        paint.setAlpha(alpha);
        invalidateSelf();
    }

    @Override
    public void setColorFilter(ColorFilter cf) {
        paint.setColorFilter(cf);
        invalidateSelf();
    }

    @Override
    public int getOpacity() {
        return PixelFormat.TRANSLUCENT;
    }
}
