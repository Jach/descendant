(in-package #:com.thejach.descendant.renderer.gl)

;;;; The cell shader, desktop GL.
;;;;
;;;; This file and renderer-gl-shaders-es.lisp define the same two variables and only one
;;;; of them is built -- see the :IF-FEATURE pair in descendant.asd. Diffing the two is
;;;; the shortest account of what GLES asks for that desktop GL does not, which is why
;;;; they are kept as whole copies rather than one string with conditionals threaded
;;;; through it.

(defparameter *vertex-shader* "#version 330 core
// No vertex buffer: one oversized triangle covering the viewport, from the vertex index.
void main() {
  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}")

(defparameter *fragment-shader* "#version 330 core
uniform usampler2D cells;   // R = character, B = mod, A = colour pair
uniform sampler2D atlas;    // R8, lit pixels of the 4x6 font
uniform vec3 palette[16];
uniform int fgSlots[16];    // low nibble of the pair -> palette slot
uniform int bgSlots[16];    // high nibble -> palette slot
uniform ivec2 cellSize;
uniform ivec2 gridSize;
uniform int atlasCols;
uniform vec2 outputSize;    // the drawable, which is not 960x720 in fullscreen

out vec4 color;

void main() {
  // Scale the 960x720 picture into the drawable, keeping its aspect and centring it.
  // The SDL path gets this from SDL_RenderSetLogicalSize; here it is arithmetic, and it
  // has to be, because F11 makes the window the size of the desktop.
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
