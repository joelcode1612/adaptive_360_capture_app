package com.adaptive360.adaptive_360_capture_app.ar

import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Minimal GLES 2.0 renderer for the AR view.
 *
 * It draws exactly two things, in this order, into the EGL window surface that
 * backs the Flutter texture:
 *
 * 1. the ARCore camera image, sampled from the external OES texture ARCore
 *    writes to, with the texture coordinates ARCore itself supplies (so the
 *    crop/aspect handling is ARCore's, not ours);
 * 2. the capture-target mesh, transformed by `projection * view * model` where
 *    `view` and `projection` are the matrices ARCore reports for the current
 *    frame and `model` is the *anchor's* pose composed with a local rotation and
 *    scale supplied by Dart.
 *
 * There is no scene graph and no model loader: the triangles are parsed from the
 * shipped `.glb` files by the pure-Dart parser in `platform/glb/` and uploaded
 * here as raw float buffers. That keeps the assets byte-for-byte and keeps the
 * geometry under the same unit tests as the rest of the app.
 */
internal class ArGlRenderer {
    private var cameraProgram = 0
    private var cameraPositionAttr = 0
    private var cameraTexCoordAttr = 0
    private var cameraTextureUniform = 0

    private var meshProgram = 0
    private var meshPositionAttr = 0
    private var meshColorAttr = 0
    private var meshMvpUniform = 0
    private var meshTintUniform = 0
    private var meshUseTintUniform = 0
    private var meshOpacityUniform = 0

    /** The external OES texture ARCore renders the camera into. */
    var cameraTextureId = 0
        private set

    /**
     * The full-screen quad, in OpenGL normalised device coordinates.
     *
     * **Must be a direct, native-order buffer.** `GLES20.glVertexAttribPointer`
     * resolves a `Buffer` to a native pointer and throws
     * `IllegalArgumentException("Must use a native order direct buffer")` for a
     * heap buffer. `FloatBuffer.allocate()` returns a heap buffer; that was the
     * cause of the exception that killed every frame and left the camera black.
     */
    private val quadCoords = directFloatBuffer(8).apply {
        put(
            floatArrayOf(
                -1.0f, -1.0f, // 0 bottom-left
                1.0f, -1.0f, // 1 bottom-right
                -1.0f, 1.0f, // 2 top-left
                1.0f, 1.0f, // 3 top-right
            ),
        )
        position(0)
    }

    /**
     * Destination of `transformCoordinates2d`; filled every frame by ARCore.
     * Direct for the same reason as [quadCoords] — it is handed straight to
     * `glVertexAttribPointer`.
     */
    private val cameraUvs = directFloatBuffer(8)

    private val viewMatrix = FloatArray(16)
    private val projectionMatrix = FloatArray(16)
    private val viewProjection = FloatArray(16)
    private val modelMatrix = FloatArray(16)
    private val scratch = FloatArray(16)
    private val mvp = FloatArray(16)

    private var surfaceWidth = 1
    private var surfaceHeight = 1

    /** Uploaded meshes, keyed by the id Dart assigned them. */
    private val meshes = HashMap<String, Mesh>()

    fun onSurfaceCreated() {
        cameraProgram = GlUtil.createProgram(CAMERA_VERTEX_SHADER, CAMERA_FRAGMENT_SHADER)
        cameraPositionAttr = GLES20.glGetAttribLocation(cameraProgram, "a_Position")
        cameraTexCoordAttr = GLES20.glGetAttribLocation(cameraProgram, "a_CamTexCoord")
        cameraTextureUniform = GLES20.glGetUniformLocation(cameraProgram, "u_CameraTexture")

        meshProgram = GlUtil.createProgram(MESH_VERTEX_SHADER, MESH_FRAGMENT_SHADER)
        meshPositionAttr = GLES20.glGetAttribLocation(meshProgram, "a_Position")
        meshColorAttr = GLES20.glGetAttribLocation(meshProgram, "a_Color")
        meshMvpUniform = GLES20.glGetUniformLocation(meshProgram, "u_Mvp")
        meshTintUniform = GLES20.glGetUniformLocation(meshProgram, "u_Tint")
        meshUseTintUniform = GLES20.glGetUniformLocation(meshProgram, "u_UseTint")
        meshOpacityUniform = GLES20.glGetUniformLocation(meshProgram, "u_Opacity")

        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        cameraTextureId = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTextureId)
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_S,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_WRAP_T,
            GLES20.GL_CLAMP_TO_EDGE,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MIN_FILTER,
            GLES20.GL_LINEAR,
        )
        GLES20.glTexParameteri(
            GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
            GLES20.GL_TEXTURE_MAG_FILTER,
            GLES20.GL_LINEAR,
        )
        GlUtil.checkGlError("camera texture")
    }

    fun onSurfaceChanged(width: Int, height: Int) {
        surfaceWidth = width.coerceAtLeast(1)
        surfaceHeight = height.coerceAtLeast(1)
    }

    /**
     * Replaces the geometry of [id].
     *
     * [positions] is xyz per vertex, [colors] is rgba per vertex; both are the
     * buffers Dart produced from the shipped GLB, so their length is the vertex
     * count times 3 / 4 respectively.
     */
    fun setMesh(id: String, positions: FloatArray, colors: FloatArray) {
        val vertexCount = positions.size / 3
        if (vertexCount == 0 || colors.size < vertexCount * 4) {
            meshes.remove(id)
            return
        }
        meshes[id]?.release()
        meshes[id] = Mesh(vertexCount, positions, colors)
    }

    fun clearMeshes() {
        meshes.values.forEach { it.release() }
        meshes.clear()
    }

    /** Sets the texture coordinates for the camera quad from ARCore. */
    fun setCameraUvs(uvs: FloatArray) {
        cameraUvs.position(0)
        cameraUvs.put(uvs)
        cameraUvs.position(0)
    }

    fun setViewProjection(view: FloatArray, projection: FloatArray) {
        System.arraycopy(view, 0, viewMatrix, 0, 16)
        System.arraycopy(projection, 0, projectionMatrix, 0, 16)
        Matrix.multiplyMM(viewProjection, 0, projectionMatrix, 0, viewMatrix, 0)
    }

    /**
     * Draws one frame: the camera image, then every visible mesh.
     *
     * [draws] is built by the caller from Dart's "what should be in the scene
     * right now" request, so nothing about target selection or anchoring lives
     * here.
     */
    fun draw(draws: List<DrawRequest>) {
        GLES20.glViewport(0, 0, surfaceWidth, surfaceHeight)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)

        drawCamera()

        GLES20.glEnable(GLES20.GL_DEPTH_TEST)
        GLES20.glEnable(GLES20.GL_BLEND)
        GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
        GLES20.glUseProgram(meshProgram)
        for (draw in draws) {
            val mesh = meshes[draw.meshId] ?: continue
            buildModelMatrix(draw)
            Matrix.multiplyMM(mvp, 0, viewProjection, 0, modelMatrix, 0)
            GLES20.glUniformMatrix4fv(meshMvpUniform, 1, false, mvp, 0)
            GLES20.glUniform4f(
                meshTintUniform,
                draw.tintR,
                draw.tintG,
                draw.tintB,
                draw.tintA,
            )
            GLES20.glUniform1f(meshUseTintUniform, if (draw.useTint) 1f else 0f)
            GLES20.glUniform1f(meshOpacityUniform, draw.opacity)

            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, mesh.positionBufferId)
            GLES20.glEnableVertexAttribArray(meshPositionAttr)
            GLES20.glVertexAttribPointer(meshPositionAttr, 3, GLES20.GL_FLOAT, false, 0, 0)

            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, mesh.colorBufferId)
            GLES20.glEnableVertexAttribArray(meshColorAttr)
            GLES20.glVertexAttribPointer(meshColorAttr, 4, GLES20.GL_FLOAT, false, 0, 0)

            GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, mesh.vertexCount)
        }
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glDisable(GLES20.GL_BLEND)
    }

    private fun drawCamera() {
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glUseProgram(cameraProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTextureId)
        GLES20.glUniform1i(cameraTextureUniform, 0)

        quadCoords.position(0)
        GLES20.glVertexAttribPointer(cameraPositionAttr, 2, GLES20.GL_FLOAT, false, 0, quadCoords)
        cameraUvs.position(0)
        GLES20.glVertexAttribPointer(cameraTexCoordAttr, 2, GLES20.GL_FLOAT, false, 0, cameraUvs)
        GLES20.glEnableVertexAttribArray(cameraPositionAttr)
        GLES20.glEnableVertexAttribArray(cameraTexCoordAttr)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(cameraPositionAttr)
        GLES20.glDisableVertexAttribArray(cameraTexCoordAttr)
    }

    /**
     * `model = anchor × local × translate(offset) × scale`, column-major.
     *
     * The anchor matrix is what makes the marker world-fixed: it is ARCore's own
     * pose for the anchor, re-read every frame, so the marker drifts with the
     * room rather than being re-derived from screen coordinates.
     *
     * [DrawRequest.modelMatrix], when present, is the **authoritative local
     * basis**, computed once by `VioSphereEngine.buildModelMatrix` in Dart. It
     * is a column-major `[X | Y | Z | worldPosition]` whose `+Z` points from the
     * target back at the station. Only its rotation is used here — the
     * translation column is zeroed, because the anchor (created at that same
     * world position, with identity orientation) is what carries the world
     * translation, so the marker stays glued to ARCore's current world estimate.
     * Using both translations, or composing the anchor's rotation with this
     * basis, would move or turn the marker twice.
     *
     * Both matrices are column-major and are uploaded with `transpose = false`,
     * so the array is consumed unchanged — no transposition anywhere.
     *
     * `quaternionToMatrix(localRotation)` remains the fallback for callers that
     * have no matrix (the pre-existing sensor flow), and produces the same axis:
     * `localRotation` maps the model's `+Z` onto the same inward facing normal.
     */
    private fun buildModelMatrix(draw: DrawRequest) {
        // `android.opengl.Matrix.multiplyMM` must not alias its result with an
        // input, so the anchor matrix is read from Dart's own array rather than
        // copied into `modelMatrix` first.
        val basis = draw.modelMatrix
        if (basis != null && basis.size >= 16) {
            System.arraycopy(basis, 0, scratch, 0, 16)
            // A station anchor owns a complete local target transform. The
            // legacy per-target path only consumes the model basis because its
            // anchor already supplies the world translation.
            if (!draw.useModelTranslation) {
                scratch[12] = 0f
                scratch[13] = 0f
                scratch[14] = 0f
            }
            scratch[15] = 1f
        } else {
            quaternionToMatrix(draw.localRotation, scratch)
        }
        Matrix.multiplyMM(modelMatrix, 0, draw.anchorMatrix, 0, scratch, 0)
        Matrix.translateM(modelMatrix, 0, draw.offsetX, draw.offsetY, draw.offsetZ)
        Matrix.scaleM(modelMatrix, 0, draw.scale, draw.scale, draw.scale)
    }

    fun release() {
        clearMeshes()
        if (cameraTextureId != 0) {
            GLES20.glDeleteTextures(1, intArrayOf(cameraTextureId), 0)
            cameraTextureId = 0
        }
        if (cameraProgram != 0) GLES20.glDeleteProgram(cameraProgram)
        if (meshProgram != 0) GLES20.glDeleteProgram(meshProgram)
        cameraProgram = 0
        meshProgram = 0
    }

    /** One thing to draw this frame. All fields are plain data from Dart. */
    class DrawRequest(
        val meshId: String,
        val anchorMatrix: FloatArray,
        val localRotation: FloatArray,
        val scale: Float,
        val offsetX: Float,
        val offsetY: Float,
        val offsetZ: Float,
        val tintR: Float,
        val tintG: Float,
        val tintB: Float,
        val tintA: Float,
        val useTint: Boolean,
        val opacity: Float,
        /**
         * The engine's column-major local basis, or `null` to fall back to
         * [localRotation]. See [buildModelMatrix].
         */
        val modelMatrix: FloatArray? = null,
        val useModelTranslation: Boolean = false,
    )

    private class Mesh(
        val vertexCount: Int,
        positions: FloatArray,
        colors: FloatArray,
    ) {
        val positionBufferId: Int
        val colorBufferId: Int

        init {
            val ids = IntArray(2)
            GLES20.glGenBuffers(2, ids, 0)
            positionBufferId = ids[0]
            colorBufferId = ids[1]
            upload(positionBufferId, positions)
            upload(colorBufferId, colors)
        }

        private fun upload(id: Int, data: FloatArray) {
            val buffer = directFloatBuffer(data.size)
            buffer.put(data)
            buffer.position(0)
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, id)
            GLES20.glBufferData(
                GLES20.GL_ARRAY_BUFFER,
                data.size * 4,
                buffer,
                GLES20.GL_STATIC_DRAW,
            )
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
        }

        fun release() {
            GLES20.glDeleteBuffers(2, intArrayOf(positionBufferId, colorBufferId), 0)
        }
    }

    companion object {
        private val CAMERA_VERTEX_SHADER = """
            attribute vec4 a_Position;
            attribute vec2 a_CamTexCoord;
            varying vec2 v_CamTexCoord;
            void main() {
              gl_Position = a_Position;
              v_CamTexCoord = a_CamTexCoord;
            }
        """.trimIndent()

        private val CAMERA_FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES u_CameraTexture;
            varying vec2 v_CamTexCoord;
            void main() {
              gl_FragColor = texture2D(u_CameraTexture, v_CamTexCoord);
            }
        """.trimIndent()

        private val MESH_VERTEX_SHADER = """
            attribute vec4 a_Position;
            attribute vec4 a_Color;
            uniform mat4 u_Mvp;
            varying vec4 v_Color;
            void main() {
              gl_Position = u_Mvp * a_Position;
              v_Color = a_Color;
            }
        """.trimIndent()

        private val MESH_FRAGMENT_SHADER = """
            precision mediump float;
            uniform vec4 u_Tint;
            uniform float u_UseTint;
            uniform float u_Opacity;
            varying vec4 v_Color;
            void main() {
              vec4 base = mix(v_Color, u_Tint, u_UseTint);
              gl_FragColor = vec4(base.rgb, base.a * u_Opacity);
            }
        """.trimIndent()

        /**
         * Unit quaternion (x, y, z, w) → column-major 4×4 rotation matrix.
         *
         * Written out rather than routed through `android.opengl.Matrix` because
         * that class only accepts axis/angle, and Dart holds the orientation as a
         * quaternion.
         */
        fun quaternionToMatrix(q: FloatArray, out: FloatArray) {
            val x = q[0]
            val y = q[1]
            val z = q[2]
            val w = q[3]
            val x2 = x + x
            val y2 = y + y
            val z2 = z + z
            val xx = x * x2
            val xy = x * y2
            val xz = x * z2
            val yy = y * y2
            val yz = y * z2
            val zz = z * z2
            val wx = w * x2
            val wy = w * y2
            val wz = w * z2
            out[0] = 1 - (yy + zz)
            out[1] = xy + wz
            out[2] = xz - wy
            out[3] = 0f
            out[4] = xy - wz
            out[5] = 1 - (xx + zz)
            out[6] = yz + wx
            out[7] = 0f
            out[8] = xz + wy
            out[9] = yz - wx
            out[10] = 1 - (xx + yy)
            out[11] = 0f
            out[12] = 0f
            out[13] = 0f
            out[14] = 0f
            out[15] = 1f
        }
    }
}

/**
 * A direct, native-order float buffer.
 *
 * Every buffer that reaches `glVertexAttribPointer` or `glBufferData` must be
 * direct and in native byte order. `FloatBuffer.allocate()` — the obvious
 * looking constructor — produces a *heap* buffer, and passing one to GLES
 * throws `IllegalArgumentException("Must use a native order direct buffer")`.
 * There is exactly one way to build one in this file, and it is this.
 */
internal fun directFloatBuffer(floats: Int): FloatBuffer =
    ByteBuffer.allocateDirect(floats * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()

/** Shader compilation and GL error checking. */
internal object GlUtil {
    fun createProgram(vertexSource: String, fragmentSource: String): Int {
        val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, vertexSource)
        val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSource)
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertexShader)
        GLES20.glAttachShader(program, fragmentShader)
        GLES20.glLinkProgram(program)
        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] == 0) {
            val message = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            throw RuntimeException("GL program link failed: $message")
        }
        GLES20.glDeleteShader(vertexShader)
        GLES20.glDeleteShader(fragmentShader)
        return program
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val message = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw RuntimeException("GL shader compile failed: $message")
        }
        return shader
    }

    fun checkGlError(op: String) {
        val error = GLES20.glGetError()
        if (error != GLES20.GL_NO_ERROR) {
            throw RuntimeException("$op: GL error 0x${Integer.toHexString(error)}")
        }
    }
}
