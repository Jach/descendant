(in-package #:com.thejach.descendant.renderer.gl)

;;;; The cell shader, OpenGL ES 3.0 -- Android.
;;;;
;;;; A copy of renderer-gl-shaders.lisp with three differences, and nothing else changed.
;;;; Diff the two files and the list below is what comes back.
;;;;
;;;;   1. "#version 300 es" rather than "#version 330 core". GLSL ES 3.00 is the ES
;;;;      dialect of roughly GLSL 3.30, and everything this shader needs is in it:
;;;;      usampler2D, texelFetch, gl_VertexID, integer textures.
;;;;
;;;;   2. Precision qualifiers. Desktop GL defines a default precision for every type;
;;;;      GLSL ES defines one for floats in vertex shaders and NOTHING for floats,
;;;;      integers or samplers in fragment shaders. A fragment shader that does not
;;;;      declare them fails to compile -- it is not a warning and not a fallback.
;;;;
;;;;   3. The letterbox comment mentions the drawable rather than F11, because on a phone
;;;;      the window is always the size of the screen and there is nothing to toggle.
;;;;
;;;; What is NOT different is worth stating: the arithmetic, the texture formats, the
;;;; uniforms and their names. RENDERER-GL.LISP compiles whichever of these it is given
;;;; and has no idea which, and the pixel-for-pixel comparison against the SLO renderer
;;;; (RENDER-TO-ARRAY) is meant to hold on both.

(defparameter *vertex-shader* "#version 300 es
// No vertex buffer: one oversized triangle covering the viewport, from the vertex index.
void main() {
  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}")

(defparameter *fragment-shader* "#version 300 es
precision highp float;
precision highp int;
precision highp usampler2D;
precision highp sampler2D;

uniform usampler2D cells;   // R = character, B = mod, A = colour pair
uniform sampler2D atlas;    // R8, lit pixels of the 4x6 font
uniform vec3 palette[16];
uniform int fgSlots[16];    // low nibble of the pair -> palette slot
uniform int bgSlots[16];    // high nibble -> palette slot
uniform ivec2 cellSize;
uniform ivec2 gridSize;
uniform int atlasCols;
uniform vec2 outputSize;    // the drawable, which is the whole screen here

out vec4 color;

void main() {
  // Scale the 960x720 picture into the drawable, keeping its aspect and centring it.
  // On a 2480x1116 phone that is 1.55x, so the picture is pillarboxed rather than
  // filling the width.
  vec2 target = vec2(gridSize * cellSize);
  float scale = min(outputSize.x / target.x, outputSize.y / target.y);
  vec2 origin = (outputSize - target * scale) * 0.5;
  vec2 local = (gl_FragCoord.xy - origin) / scale;

  if (local.x < 0.0 || local.y < 0.0 || local.x >= target.x || local.y >= target.y) {
    color = vec4(0.0, 0.0, 0.0, 1.0);   // the letterbox
    return;
  }

  ivec2 px = ivec2(local);
  // GL counts rows up from the bottom; the cell buffer counts down from the top.
  px.y = int(target.y) - 1 - px.y;

  ivec2 cell = px / cellSize;
  ivec2 inCell = px % cellSize;

  uvec4 c = texelFetch(cells, cell, 0);
  int ch = int(c.r);
  int pair = int(c.a);

  int fg = fgSlots[pair & 15];
  int bg = bgSlots[(pair >> 4) & 15];

  ivec2 tile = ivec2(ch % atlasCols, ch / atlasCols);
  float lit = texelFetch(atlas, tile * cellSize + inCell, 0).r;

  color = vec4(lit > 0.5 ? palette[fg] : palette[bg], 1.0);
}")
