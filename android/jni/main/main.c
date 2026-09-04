/*
 * The Descendant -- Android entry point.
 *
 * This is the only C in the port, and it exists because an Android app is not a program
 * that gets run. SDL's activity loads libSDL2.so and then libmain.so, dlsyms SDL_main out
 * of the latter, and calls it on a thread of SDL's own making. So there is no main(), and
 * the process was started by the Android runtime, not by us.
 *
 * Three jobs:
 *
 *   1. Export SDL_main.
 *   2. Put stdout and stderr somewhere visible. On Android fd 1 goes nowhere, so without
 *      this every printf in the game -- and every complaint SBCL makes on the way up --
 *      is silently discarded. This is the difference between debugging and guessing.
 *   3. Start Lisp and hand over.
 *
 * Job 3 is compiled out unless DESCENDANT_LISP is defined, which is what makes this file
 * serve both M0 and M2 of android/PLAN.md. Without it, SDL_main runs a self-contained
 * probe instead: open a GLES 3 context, report what the device actually gave us, and log
 * touch input. That probe is not a toy -- it answers several questions the Lisp port would
 * otherwise have to discover the hard way, and it answers them with no Lisp in the
 * picture at all, so a failure means something unambiguous.
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>

#include <android/log.h>
#include <SDL.h>
#include <GLES2/gl2.h>

#define TAG "descendant"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/* ------------------------------------------------------------------------- */
/* stdout/stderr -> logcat                                                    */

static int log_pipe[2];

static void *log_pump(void *unused)
{
    char buf[512];
    ssize_t n;
    (void)unused;
    while ((n = read(log_pipe[0], buf, sizeof buf - 1)) > 0) {
        while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) n--;
        buf[n] = '\0';
        if (n > 0) __android_log_write(ANDROID_LOG_INFO, TAG, buf);
    }
    return NULL;
}

static void redirect_stdio_to_logcat(void)
{
    pthread_t thread;

    /* Line buffering on stdout, none on stderr: an unflushed buffer at the moment of a
       crash is exactly the output worth having. */
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    if (pipe(log_pipe) != 0) {
        LOGE("could not create the logcat pipe: %s", strerror(errno));
        return;
    }
    dup2(log_pipe[1], STDOUT_FILENO);
    dup2(log_pipe[1], STDERR_FILENO);

    if (pthread_create(&thread, NULL, log_pump, NULL) == 0)
        pthread_detach(thread);
}

/* ------------------------------------------------------------------------- */
/* M0: the probe                                                              */

#ifndef DESCENDANT_LISP

static void report_environment(void)
{
    const char *internal = SDL_AndroidGetInternalStoragePath();

    LOGI("SDL      %d.%d.%d", SDL_MAJOR_VERSION, SDL_MINOR_VERSION, SDL_PATCHLEVEL);
    LOGI("platform %s, %d cores, %d MB RAM",
         SDL_GetPlatform(), SDL_GetCPUCount(), SDL_GetSystemRAM());

    /* Where assets/ will be extracted to, and where options.ini and the score table will
       live. PATHS:APP-ROOT needs exactly this string, so print it now and the Lisp side
       has one less thing to discover. */
    LOGI("internal storage: %s", internal ? internal : "(null)");
}

static void report_gl(void)
{
    /* The one thing worth knowing before writing an ES shader: what the driver calls
       itself. The port's fast renderer needs GLSL ES 3.00 for usampler2D and texelFetch,
       so "OpenGL ES 3.x" here is the go-ahead for PLAN.md 6.3. */
    LOGI("GL_VERSION   %s", (const char *)glGetString(GL_VERSION));
    LOGI("GL_RENDERER  %s", (const char *)glGetString(GL_RENDERER));
    LOGI("GL_VENDOR    %s", (const char *)glGetString(GL_VENDOR));
    LOGI("GLSL         %s", (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION));
}

static int probe(void)
{
    SDL_Window *window;
    SDL_GLContext context;
    SDL_Event event;
    int running = 1;
    int frame = 0;
    int w = 0, h = 0;

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) != 0) {
        LOGE("SDL_Init: %s", SDL_GetError());
        return 1;
    }
    report_environment();

    /* The same request main.lisp will make, in its ES spelling. */
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);

    window = SDL_CreateWindow("The Descendant", SDL_WINDOWPOS_UNDEFINED,
                              SDL_WINDOWPOS_UNDEFINED, 0, 0,
                              SDL_WINDOW_FULLSCREEN | SDL_WINDOW_OPENGL);
    if (!window) {
        LOGE("SDL_CreateWindow: %s", SDL_GetError());
        return 1;
    }

    context = SDL_GL_CreateContext(window);
    if (!context) {
        LOGE("SDL_GL_CreateContext: %s", SDL_GetError());
        return 1;
    }
    report_gl();

    SDL_GL_GetDrawableSize(window, &w, &h);
    LOGI("drawable %dx%d -- the game draws 960x720 and letterboxes into this", w, h);

    /* Vsync off. The game paces itself at 62.5 Hz and a blocking swap would fight it. */
    SDL_GL_SetSwapInterval(0);

    /* Back button as an event rather than an exit, which is how Escape gets onto a
       phone that has no Escape. */
    SDL_SetHint(SDL_HINT_ANDROID_TRAP_BACK_BUTTON, "1");

    LOGI("entering the loop -- touch the screen, then press back to quit");

    while (running) {
        while (SDL_PollEvent(&event)) {
            switch (event.type) {
            case SDL_QUIT:
                running = 0;
                break;
            case SDL_FINGERDOWN:
            case SDL_FINGERMOTION:
            case SDL_FINGERUP:
                /* Normalised 0..1, independent of window and logical size -- which is
                   why the virtual joystick in PLAN.md 6.1 needs no coordinate mapping. */
                LOGI("finger %s id=%lld x=%.3f y=%.3f",
                     event.type == SDL_FINGERDOWN ? "down" :
                     event.type == SDL_FINGERUP   ? "up"   : "move",
                     (long long)event.tfinger.fingerId,
                     event.tfinger.x, event.tfinger.y);
                break;
            case SDL_KEYDOWN:
                LOGI("key scancode=%d (AC_BACK is %d)",
                     event.key.keysym.scancode, SDL_SCANCODE_AC_BACK);
                if (event.key.keysym.scancode == SDL_SCANCODE_AC_BACK) running = 0;
                break;
            case SDL_APP_WILLENTERBACKGROUND:
                LOGI("backgrounding");
                break;
            case SDL_APP_DIDENTERFOREGROUND:
                LOGI("foregrounded -- if the GL context was lost, this is where we rebuild");
                break;
            default:
                break;
            }
        }

        /* Something visibly alive, and a check that swapping works. */
        glClearColor((float)((frame / 2) % 256) / 255.0f, 0.0f, 0.15f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        SDL_GL_SwapWindow(window);

        if (++frame % 300 == 0) LOGI("frame %d", frame);
        SDL_Delay(16);
    }

    LOGI("shutting down cleanly after %d frames", frame);
    SDL_GL_DeleteContext(context);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}

#endif /* !DESCENDANT_LISP */

/* ------------------------------------------------------------------------- */
/* M2: hand over to Lisp                                                      */

#ifdef DESCENDANT_LISP

#include <dlfcn.h>
#include <limits.h>

/* From libsbcl.so. It does not return: SBCL's own main() calls lose() if it ever does,
 * because create_main_lisp_thread hands control to the Lisp toplevel and stays there. */
extern int initialize_lisp(int argc, char **argv, char **envp);

extern char **environ;

/* Where our own .so was loaded from, which is where everything else in lib/arm64-v8a/
 * ended up too.
 *
 * Asked of the dynamic linker rather than assumed, because the path carries two
 * installation-specific hashes:
 *
 *   /data/app/~~RPA4Ts.../com.thejach.descendant-qumGz.../lib/arm64/
 *
 * That directory is the only place an app controls where a file may be mapped
 * executable, which is where the core has to live unless it is compressed (PLAN.md 7.2). */
static const char *native_lib_dir(void)
{
    static char dir[PATH_MAX];
    Dl_info info;
    char *slash;

    if (!dladdr((void *)&native_lib_dir, &info) || !info.dli_fname) {
        LOGE("dladdr could not find our own library");
        return NULL;
    }
    snprintf(dir, sizeof dir, "%s", info.dli_fname);
    slash = strrchr(dir, '/');
    if (!slash) return NULL;
    *slash = '\0';
    return dir;
}

/* What Lisp is asked to do.
 *
 * Deliberately more than printing. Consing a few megabytes and then forcing a full
 * collection exercises the two things most likely to go wrong inside an ART process --
 * the mmap'd heap, and whatever the collector wants from signals. A hello-world that only
 * printed would prove the core loaded and nothing else, and the core loading was never
 * the interesting part. */
static const char *LISP_PROBE =
  "(handler-case"
  "  (progn"
  "    (format t \"lisp: ~a ~a on ~a~%\""
  "            (lisp-implementation-type) (lisp-implementation-version) (machine-type))"
  "    (format t \"lisp: dynamic-space ~:d bytes~%\" (sb-ext:dynamic-space-size))"
  "    (let ((junk (make-array 400000)))"
  "      (dotimes (i (length junk)) (setf (aref junk i) (list i (* i 1.5))))"
  "      (format t \"lisp: allocated ~:d conses~%\" (length junk)))"
  "    (sb-ext:gc :full t)"
  "    (format t \"lisp: full gc survived, ~:d bytes consed~%\" (sb-ext:get-bytes-consed))"
  "    (format t \"lisp: OK~%\"))"
  "  (error (e) (format t \"lisp: FAILED ~a~%\" e)))";

static int start_lisp(void)
{
    static char core[PATH_MAX];
    const char *dir = native_lib_dir();

    if (!dir) return 1;
    snprintf(core, sizeof core, "%s/libsbclcore.so", dir);
    printf("descendant: core is %s\n", core);

    /* 512 MB rather than the desktop build's 2 GB. Address space is reserved rather than
     * committed, but there is no reason to ask a phone for headroom the game never uses. */
    char *args[] = {
        "descendant",
        "--core", core,
        "--dynamic-space-size", "512MB",
        "--noinform",
        "--no-sysinit", "--no-userinit",
        "--disable-debugger",
        "--eval", (char *)LISP_PROBE,
        "--quit",
        NULL
    };
    int argc = (int)(sizeof args / sizeof args[0]) - 1;

    printf("descendant: calling initialize_lisp\n");
    initialize_lisp(argc, args, environ);

    LOGE("initialize_lisp returned, which it is not supposed to do");
    return 1;
}

#endif /* DESCENDANT_LISP */

/* ------------------------------------------------------------------------- */

int SDL_main(int argc, char *argv[])
{
    (void)argc;
    (void)argv;

    redirect_stdio_to_logcat();
    printf("descendant: SDL_main entered on thread %lu\n",
           (unsigned long)pthread_self());

#ifdef DESCENDANT_LISP
    return start_lisp();
#else
    return probe();
#endif
}
