package com.adaptive360.adaptive_360_capture_app.ar

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.media.Image
import java.io.ByteArrayOutputStream

/**
 * Turns an ARCore camera image into a display-oriented JPEG — in two halves.
 *
 * **Why this file exists.** ARCore holds the camera device exclusively, so the
 * only stills available while a session is live are the ones
 * `Frame.acquireCameraImage()` hands over. Those arrive as an
 * `ImageFormat.YUV_420_888` `Image` in the *sensor's* orientation, which on a
 * phone is landscape while the app is portrait-locked. Writing those bytes out
 * unrotated would save a sideways photograph, so the rotation has to happen
 * here, on the raw planes, before a single JPEG byte is produced. Doing it on
 * the decoded JPEG instead would cost a second lossy encode.
 *
 * **Why it is split in two.** A camera `Image` is valid only until the next
 * `Session.update()` — the next render tick. And `compressToJpeg` is tens of
 * milliseconds of CPU work that used to run on the AR thread, stalling the
 * frame after the photograph. So the two halves are split per lifetime: the
 * *snapshot* ([snapshot]) copies the planes into plain arrays on the thread
 * that still holds the `Image`, and the *encode* ([encode]) runs on a worker,
 * safe against arrays that no longer depend on the session.
 *
 * The rotation is **not** a hard-coded constant. [encode] takes the direction in
 * display coordinates that ARCore says the image's own +x axis points along,
 * read once per session from `Frame.transformCoordinates2d`, and derives the
 * output geometry from it. That makes a 0°, 90°, 180° or 270° sensor — or a
 * device that disagrees with the usual assumption — a measured input rather than
 * a guess.
 *
 * Output is NV21 fed to [YuvImage], which is the platform's own encoder: one
 * encode, no intermediate `Bitmap`, and no resampling.
 */
internal object YuvJpegEncoder {
    /** JPEG bytes plus the dimensions after display-orientation rotation. */
    internal class EncodedJpeg(
        val bytes: ByteArray,
        val width: Int,
        val height: Int,
    )

    /** One image plane, copied off the camera `Image` while it was valid. */
    internal class PlaneBytes(
        val bytes: ByteArray,
        val rowStride: Int,
        val pixelStride: Int,
    )

    /**
     * A camera image, copied to plain arrays that outlive the `Image`.
     *
     * [planeBytes] sizes each copy to the buffer's own capacity, the only
     * length that is honest for both planar and packed `pixelStride == 2`
     * chroma: `rowStride * rows` can exceed the backing buffer there, and
     * copying to that size is what used to throw `IndexOutOfBoundsException`
     * on the very devices that matter.
     */
    internal class PlaneSnapshot(
        val width: Int,
        val height: Int,
        val y: PlaneBytes,
        val u: PlaneBytes,
        val v: PlaneBytes,
    )

    /**
     * Copies [image]'s planes off the camera. Null when the image is absent or
     * not `YUV_420_888`, which the caller reports as "the AR session could not
     * produce a photograph" rather than substituting something else.
     *
     * Must run on the thread that holds the `Image` — i.e. the AR thread.
     */
    fun snapshot(image: Image?): PlaneSnapshot? {
        if (image == null) return null
        if (image.format != ImageFormat.YUV_420_888) return null
        val planes = image.planes
        if (planes.size < 3) return null

        val width = image.width
        val height = image.height
        if (width <= 0 || height <= 0) return null

        val y = planeBytes(planes[0]) ?: return null
        val u = planeBytes(planes[1]) ?: return null
        val v = planeBytes(planes[2]) ?: return null
        return PlaneSnapshot(width, height, y, u, v)
    }

    private fun planeBytes(plane: Image.Plane): PlaneBytes? {
        val buffer = plane.buffer
        val copy = ByteArray(buffer.remaining())
        buffer.rewind()
        buffer.get(copy)
        return PlaneBytes(copy, plane.rowStride, plane.pixelStride)
    }

    /**
     * Encodes a [PlaneSnapshot] to JPEG.
     *
     * [imageAxisXInView] is the unit direction `(dx, dy)`, in Android view
     * coordinates (x right, y down), along which the image's own +x axis lies.
     * Pass the value captured at snapshot time — a resumed session re-measures
     * it, and an old photograph must use the axis its own pixels were taken
     * under. Runs off the AR thread: nothing here touches the session.
     */
    fun encode(
        snapshot: PlaneSnapshot,
        imageAxisXInView: FloatArray,
        quality: Int,
    ): EncodedJpeg? {
        val width = snapshot.width
        val height = snapshot.height

        // Snap to the nearest quarter turn. The image→view transform is a
        // rotation by a multiple of 90°, so snapping is exact, and it keeps the
        // sampling maths away from floating-point drift at the edges.
        val angle = Math.atan2(imageAxisXInView[1].toDouble(), imageAxisXInView[0].toDouble())
        val quarters = ((Math.round(angle / (Math.PI / 2)).toInt()) % 4 + 4) % 4
        val dx = AXES[quarters][0]
        val dy = AXES[quarters][1]
        // The image's +y axis: +x rotated 90° clockwise in a y-down frame.
        val px = -dy
        val py = dx

        // Mapped corners, to find the output extent.
        val minX = minOf(0, (width - 1) * dx, (height - 1) * px, (width - 1) * dx + (height - 1) * px)
        val minY = minOf(0, (width - 1) * dy, (height - 1) * py, (width - 1) * dy + (height - 1) * py)
        val maxX = maxOf(0, (width - 1) * dx, (height - 1) * px, (width - 1) * dx + (height - 1) * px)
        val maxY = maxOf(0, (width - 1) * dy, (height - 1) * py, (width - 1) * dy + (height - 1) * py)
        val outW = maxX - minX + 1
        val outH = maxY - minY + 1
        if (outW <= 0 || outH <= 0) return null
        // YuvImage cannot encode an odd dimension.
        if (outW % 2 != 0 || outH % 2 != 0) return null

        val outY = rotate(snapshot.y, width, height, outW, outH, minX, minY, dx, dy, px, py)
            ?: return null

        val halfW = width / 2
        val halfH = height / 2
        val outHalfW = outW / 2
        val outHalfH = outH / 2
        val outU = rotate(
            snapshot.u, halfW, halfH, outHalfW, outHalfH,
            minX / 2, minY / 2, dx, dy, px, py,
        ) ?: return null
        val outV = rotate(
            snapshot.v, halfW, halfH, outHalfW, outHalfH,
            minX / 2, minY / 2, dx, dy, px, py,
        ) ?: return null

        // NV21 is a full Y plane followed by interleaved V/U pairs.
        val nv21 = ByteArray(outW * outH + outHalfW * outHalfH * 2)
        System.arraycopy(outY, 0, nv21, 0, outY.size)
        var o = outY.size
        for (i in 0 until outHalfW * outHalfH) {
            nv21[o++] = outV[i]
            nv21[o++] = outU[i]
        }

        val stream = ByteArrayOutputStream()
        val yuvImage = YuvImage(nv21, ImageFormat.NV21, outW, outH, null)
        val ok = yuvImage.compressToJpeg(Rect(0, 0, outW, outH), quality.coerceIn(1, 100), stream)
        return if (ok) EncodedJpeg(stream.toByteArray(), outW, outH) else null
    }

    /**
     * Samples one plane of a [PlaneSnapshot] into the rotated output.
     *
     * [planeBytes] copies the whole plane off the `Image`; this samples from
     * that copy. The source index is bounds-checked instead of assumed to lie
     * inside `rowStride * rows`: for packed `pixelStride == 2` chroma the
     * backing buffer can be shorter than the stride arithmetic suggests, and
     * trusting it was an `ArrayIndexOutOfBoundsException` thrown in the middle
     * of a photograph.
     */
    private fun rotate(
        plane: PlaneBytes,
        planeWidth: Int,
        planeHeight: Int,
        outW: Int,
        outH: Int,
        minX: Int,
        minY: Int,
        dx: Int,
        dy: Int,
        px: Int,
        py: Int,
    ): ByteArray? {
        val src = plane.bytes
        val srcLen = src.size
        val out = ByteArray(outW * outH)

        var o = 0
        for (v in 0 until outH) {
            val vy = v + minY
            for (u in 0 until outW) {
                val vx = u + minX
                var sx = vx * dx + vy * px
                var sy = vx * dy + vy * py
                if (sx < 0) sx = 0 else if (sx >= planeWidth) sx = planeWidth - 1
                if (sy < 0) sy = 0 else if (sy >= planeHeight) sy = planeHeight - 1
                val index = sy * plane.rowStride + sx * plane.pixelStride
                if (index < 0 || index >= srcLen) return null
                out[o++] = src[index]
            }
        }
        return out
    }

    /** `(1,0)`, `(0,1)`, `(-1,0)`, `(0,-1)` — snapped axis for each quarter turn. */
    private val AXES = arrayOf(
        intArrayOf(1, 0),
        intArrayOf(0, 1),
        intArrayOf(-1, 0),
        intArrayOf(0, -1),
    )
}
