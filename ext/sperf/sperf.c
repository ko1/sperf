#include <ruby.h>
#include <ruby/debug.h>
#include <ruby/thread.h>
#include <ruby/internal/intern/thread.h>
#include <pthread.h>
#include <time.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

#define SPERF_MAX_STACK_DEPTH 512
#define SPERF_INITIAL_SAMPLES 1024
#define SPERF_INITIAL_FRAME_POOL (1024 * 1024 / sizeof(VALUE)) /* ~1MB */

/* ---- Data structures ---- */

enum sperf_sample_type {
    SPERF_SAMPLE_NORMAL      = 0,
    SPERF_SAMPLE_GVL_BLOCKED = 1,  /* off-GVL: SUSPENDED → READY */
    SPERF_SAMPLE_GVL_WAIT    = 2,  /* GVL wait: READY → RESUMED */
    SPERF_SAMPLE_GC_MARKING  = 3,  /* GC marking phase */
    SPERF_SAMPLE_GC_SWEEPING = 4,  /* GC sweeping phase */
};

enum sperf_gc_phase {
    SPERF_GC_NONE     = 0,
    SPERF_GC_MARKING  = 1,
    SPERF_GC_SWEEPING = 2,
};

typedef struct sperf_sample {
    int depth;
    size_t frame_start; /* index into frame_pool */
    int64_t weight;
    int type;           /* sperf_sample_type */
} sperf_sample_t;

typedef struct sperf_thread_data {
    int64_t prev_cpu_ns;
    int64_t prev_wall_ns;
    /* GVL event tracking */
    int64_t suspended_at_ns;        /* wall time at SUSPENDED */
    int64_t ready_at_ns;            /* wall time at READY */
    size_t suspended_frame_start;   /* saved stack in frame_pool */
    int suspended_frame_depth;      /* saved stack depth */
} sperf_thread_data_t;

typedef struct sperf_profiler {
    int frequency;
    int mode; /* 0 = cpu, 1 = wall */
    volatile int running;
    pthread_t timer_thread;
    rb_postponed_job_handle_t pj_handle;
    sperf_sample_t *samples;
    size_t sample_count;
    size_t sample_capacity;
    VALUE *frame_pool;       /* raw frame VALUEs from rb_profile_thread_frames */
    size_t frame_pool_count;
    size_t frame_pool_capacity;
    rb_internal_thread_specific_key_t ts_key;
    rb_internal_thread_event_hook_t *thread_hook;
    /* GC tracking */
    int gc_phase;                /* sperf_gc_phase */
    int64_t gc_enter_ns;         /* wall time at GC_ENTER */
    size_t gc_frame_start;       /* saved stack at GC_ENTER */
    int gc_frame_depth;          /* saved stack depth */
    /* Sampling overhead stats */
    size_t sampling_count;
    int64_t sampling_total_ns;
} sperf_profiler_t;

static sperf_profiler_t g_profiler;
static VALUE g_profiler_wrapper = Qnil;

/* ---- TypedData for GC marking of frame_pool ---- */

static void
sperf_profiler_mark(void *ptr)
{
    sperf_profiler_t *prof = (sperf_profiler_t *)ptr;
    if (prof->frame_pool && prof->frame_pool_count > 0) {
        rb_gc_mark_locations(prof->frame_pool, prof->frame_pool + prof->frame_pool_count);
    }
}

static const rb_data_type_t sperf_profiler_type = {
    .wrap_struct_name = "sperf_profiler",
    .function = {
        .dmark = sperf_profiler_mark,
        .dfree = NULL,
        .dsize = NULL,
    },
};

/* ---- CPU time ---- */

static int64_t
sperf_cpu_time_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) return -1;
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ---- Wall time ---- */

static int64_t
sperf_wall_time_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ---- Get current thread's time based on profiler mode ---- */

static int64_t
sperf_current_time_ns(sperf_profiler_t *prof, sperf_thread_data_t *td)
{
    if (prof->mode == 0) {
        return sperf_cpu_time_ns();
    } else {
        return sperf_wall_time_ns();
    }
}

/* ---- Sample buffer ---- */

/* Returns 0 on success, -1 on allocation failure */
static int
sperf_ensure_sample_capacity(sperf_profiler_t *prof)
{
    if (prof->sample_count >= prof->sample_capacity) {
        size_t new_cap = prof->sample_capacity * 2;
        sperf_sample_t *new_samples = (sperf_sample_t *)realloc(
            prof->samples,
            new_cap * sizeof(sperf_sample_t));
        if (!new_samples) return -1;
        prof->samples = new_samples;
        prof->sample_capacity = new_cap;
    }
    return 0;
}

/* ---- Frame pool ---- */

/* Ensure frame_pool has room for `needed` more entries. Returns 0 on success. */
static int
sperf_ensure_frame_pool_capacity(sperf_profiler_t *prof, int needed)
{
    while (prof->frame_pool_count + (size_t)needed > prof->frame_pool_capacity) {
        size_t new_cap = prof->frame_pool_capacity * 2;
        VALUE *new_pool = (VALUE *)realloc(
            prof->frame_pool,
            new_cap * sizeof(VALUE));
        if (!new_pool) return -1;
        prof->frame_pool = new_pool;
        prof->frame_pool_capacity = new_cap;
    }
    return 0;
}

/* ---- Record a sample ---- */

static void
sperf_record_sample(sperf_profiler_t *prof, size_t frame_start, int depth,
                    int64_t weight, int type)
{
    if (weight <= 0) return;
    if (sperf_ensure_sample_capacity(prof) < 0) return;

    sperf_sample_t *sample = &prof->samples[prof->sample_count];
    sample->depth = depth;
    sample->frame_start = frame_start;
    sample->weight = weight;
    sample->type = type;
    prof->sample_count++;
}

/* ---- Thread data initialization ---- */

/* Create and initialize per-thread data. Must be called on the target thread. */
static sperf_thread_data_t *
sperf_thread_data_create(sperf_profiler_t *prof, VALUE thread)
{
    sperf_thread_data_t *td = (sperf_thread_data_t *)calloc(1, sizeof(sperf_thread_data_t));
    if (!td) return NULL;
    td->prev_cpu_ns = sperf_current_time_ns(prof, td);
    td->prev_wall_ns = sperf_wall_time_ns();
    rb_internal_thread_specific_set(thread, prof->ts_key, td);
    return td;
}

/* ---- Thread event hooks ---- */

static void
sperf_handle_suspended(sperf_profiler_t *prof, VALUE thread)
{
    /* Has GVL — safe to call Ruby APIs */
    int64_t wall_now = sperf_wall_time_ns();

    sperf_thread_data_t *td = (sperf_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);
    int is_first = 0;

    if (td == NULL) {
        td = sperf_thread_data_create(prof, thread);
        if (!td) return;
        is_first = 1;
    }

    int64_t time_now = sperf_current_time_ns(prof, td);
    if (time_now < 0) return;

    /* Capture backtrace into frame_pool */
    if (sperf_ensure_frame_pool_capacity(prof, SPERF_MAX_STACK_DEPTH) < 0) return;
    size_t frame_start = prof->frame_pool_count;
    int depth = rb_profile_thread_frames(thread, 0, SPERF_MAX_STACK_DEPTH,
                                         &prof->frame_pool[frame_start], NULL);
    if (depth <= 0) return;
    prof->frame_pool_count += depth;

    /* Record normal sample (skip if first time — no prev_time) */
    if (!is_first) {
        int64_t weight = time_now - td->prev_cpu_ns;
        sperf_record_sample(prof, frame_start, depth, weight, SPERF_SAMPLE_NORMAL);
    }

    /* Save stack and timestamp for READY/RESUMED */
    td->suspended_at_ns = wall_now;
    td->suspended_frame_start = frame_start;
    td->suspended_frame_depth = depth;
    td->prev_cpu_ns = time_now;
    td->prev_wall_ns = wall_now;
}

static void
sperf_handle_ready(sperf_profiler_t *prof, VALUE thread)
{
    /* May NOT have GVL — only simple C operations allowed */
    sperf_thread_data_t *td = (sperf_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);
    if (!td) return;

    td->ready_at_ns = sperf_wall_time_ns();
}

static void
sperf_handle_resumed(sperf_profiler_t *prof, VALUE thread)
{
    /* Has GVL */
    sperf_thread_data_t *td = (sperf_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);

    if (td == NULL) {
        td = sperf_thread_data_create(prof, thread);
        if (!td) return;
    }

    int64_t wall_now = sperf_wall_time_ns();

    /* Record GVL blocked/wait samples (wall mode only) */
    if (prof->mode == 1 && td->suspended_frame_depth > 0) {
        if (td->ready_at_ns > 0 && td->ready_at_ns > td->suspended_at_ns) {
            int64_t blocked_ns = td->ready_at_ns - td->suspended_at_ns;
            sperf_record_sample(prof, td->suspended_frame_start,
                                td->suspended_frame_depth, blocked_ns,
                                SPERF_SAMPLE_GVL_BLOCKED);
        }
        if (td->ready_at_ns > 0 && wall_now > td->ready_at_ns) {
            int64_t wait_ns = wall_now - td->ready_at_ns;
            sperf_record_sample(prof, td->suspended_frame_start,
                                td->suspended_frame_depth, wait_ns,
                                SPERF_SAMPLE_GVL_WAIT);
        }
    }

    /* Reset prev times to current — next timer sample measures from resume */
    int64_t time_now = sperf_current_time_ns(prof, td);
    if (time_now >= 0) td->prev_cpu_ns = time_now;
    td->prev_wall_ns = wall_now;

    /* Clear suspended state */
    td->suspended_frame_depth = 0;
    td->ready_at_ns = 0;
}

static void
sperf_handle_exited(sperf_profiler_t *prof, VALUE thread)
{
    sperf_thread_data_t *td = (sperf_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);
    if (td) {
        free(td);
        rb_internal_thread_specific_set(thread, prof->ts_key, NULL);
    }
}

static void
sperf_thread_event_hook(rb_event_flag_t event, const rb_internal_thread_event_data_t *data, void *user_data)
{
    sperf_profiler_t *prof = (sperf_profiler_t *)user_data;
    if (!prof->running) return;

    VALUE thread = data->thread;

    if (event & RUBY_INTERNAL_THREAD_EVENT_SUSPENDED)
        sperf_handle_suspended(prof, thread);
    else if (event & RUBY_INTERNAL_THREAD_EVENT_READY)
        sperf_handle_ready(prof, thread);
    else if (event & RUBY_INTERNAL_THREAD_EVENT_RESUMED)
        sperf_handle_resumed(prof, thread);
    else if (event & RUBY_INTERNAL_THREAD_EVENT_EXITED)
        sperf_handle_exited(prof, thread);
}

/* ---- GC event hook ---- */

static void
sperf_gc_event_hook(rb_event_flag_t event, VALUE data, VALUE self, ID id, VALUE klass)
{
    sperf_profiler_t *prof = &g_profiler;
    if (!prof->running) return;

    if (event & RUBY_INTERNAL_EVENT_GC_START) {
        prof->gc_phase = SPERF_GC_MARKING;
    }
    else if (event & RUBY_INTERNAL_EVENT_GC_END_MARK) {
        prof->gc_phase = SPERF_GC_SWEEPING;
    }
    else if (event & RUBY_INTERNAL_EVENT_GC_END_SWEEP) {
        prof->gc_phase = SPERF_GC_NONE;
    }
    else if (event & RUBY_INTERNAL_EVENT_GC_ENTER) {
        /* Capture backtrace and timestamp at GC entry */
        prof->gc_enter_ns = sperf_wall_time_ns();

        if (sperf_ensure_frame_pool_capacity(prof, SPERF_MAX_STACK_DEPTH) < 0) return;
        size_t frame_start = prof->frame_pool_count;
        VALUE thread = rb_thread_current();
        int depth = rb_profile_thread_frames(thread, 0, SPERF_MAX_STACK_DEPTH,
                                             &prof->frame_pool[frame_start], NULL);
        if (depth <= 0) {
            prof->gc_frame_depth = 0;
            return;
        }
        prof->frame_pool_count += depth;
        prof->gc_frame_start = frame_start;
        prof->gc_frame_depth = depth;
    }
    else if (event & RUBY_INTERNAL_EVENT_GC_EXIT) {
        if (prof->gc_frame_depth <= 0) return;

        int64_t wall_now = sperf_wall_time_ns();
        int64_t weight = wall_now - prof->gc_enter_ns;
        int type = (prof->gc_phase == SPERF_GC_SWEEPING)
                   ? SPERF_SAMPLE_GC_SWEEPING
                   : SPERF_SAMPLE_GC_MARKING;

        sperf_record_sample(prof, prof->gc_frame_start,
                            prof->gc_frame_depth, weight, type);
        prof->gc_frame_depth = 0;
    }
}

/* ---- Sampling callback (postponed job) — current thread only ---- */

static void
sperf_sample_job(void *arg)
{
    sperf_profiler_t *prof = (sperf_profiler_t *)arg;

    if (!prof->running) return;

    /* Measure sampling overhead */
    struct timespec ts_start, ts_end;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts_start);

    VALUE thread = rb_thread_current();

    /* Get/create per-thread data */
    sperf_thread_data_t *td = (sperf_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);
    if (td == NULL) {
        td = sperf_thread_data_create(prof, thread);
        if (!td) return;
        return; /* Skip first sample for this thread */
    }

    int64_t time_now = sperf_current_time_ns(prof, td);
    if (time_now < 0) return;

    int64_t weight = time_now - td->prev_cpu_ns;
    td->prev_cpu_ns = time_now;
    td->prev_wall_ns = sperf_wall_time_ns();

    if (weight <= 0) return;

    /* Capture backtrace and record sample */
    if (sperf_ensure_frame_pool_capacity(prof, SPERF_MAX_STACK_DEPTH) < 0) return;

    size_t frame_start = prof->frame_pool_count;
    int depth = rb_profile_thread_frames(thread, 0, SPERF_MAX_STACK_DEPTH,
                                         &prof->frame_pool[frame_start], NULL);
    if (depth <= 0) return;
    prof->frame_pool_count += depth;

    sperf_record_sample(prof, frame_start, depth, weight, SPERF_SAMPLE_NORMAL);

    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts_end);
    prof->sampling_count++;
    prof->sampling_total_ns +=
        ((int64_t)ts_end.tv_sec - ts_start.tv_sec) * 1000000000LL +
        (ts_end.tv_nsec - ts_start.tv_nsec);
}

/* ---- Timer thread ---- */

static void *
sperf_timer_func(void *arg)
{
    sperf_profiler_t *prof = (sperf_profiler_t *)arg;
    struct timespec interval;
    interval.tv_sec = 0;
    interval.tv_nsec = 1000000000L / prof->frequency;

    while (prof->running) {
        rb_postponed_job_trigger(prof->pj_handle);
        nanosleep(&interval, NULL);
    }
    return NULL;
}

/* ---- Resolve frame VALUE to [path, label] Ruby strings ---- */

static VALUE
sperf_resolve_frame(VALUE fval)
{
    VALUE path = rb_profile_frame_path(fval);
    VALUE label = rb_profile_frame_full_label(fval);

    if (NIL_P(path))  path  = rb_str_new_lit("<C method>");

    if (NIL_P(path))  path  = rb_str_new_cstr("");
    if (NIL_P(label)) label = rb_str_new_cstr("");

    return rb_ary_new3(2, path, label);
}

/* ---- Ruby API ---- */

static VALUE
rb_sperf_start(int argc, VALUE *argv, VALUE self)
{
    VALUE opts;
    int frequency = 100;
    int mode = 0; /* 0 = cpu, 1 = wall */

    rb_scan_args(argc, argv, ":", &opts);
    if (!NIL_P(opts)) {
        VALUE vfreq = rb_hash_aref(opts, ID2SYM(rb_intern("frequency")));
        if (!NIL_P(vfreq)) {
            frequency = NUM2INT(vfreq);
            if (frequency <= 0 || frequency > 1000000) {
                rb_raise(rb_eArgError, "frequency must be between 1 and 1000000");
            }
        }
        VALUE vmode = rb_hash_aref(opts, ID2SYM(rb_intern("mode")));
        if (!NIL_P(vmode)) {
            ID mode_id = SYM2ID(vmode);
            if (mode_id == rb_intern("cpu")) {
                mode = 0;
            } else if (mode_id == rb_intern("wall")) {
                mode = 1;
            } else {
                rb_raise(rb_eArgError, "mode must be :cpu or :wall");
            }
        }
    }

    if (g_profiler.running) {
        rb_raise(rb_eRuntimeError, "Sperf is already running");
    }

    g_profiler.frequency = frequency;
    g_profiler.mode = mode;
    g_profiler.sample_count = 0;
    g_profiler.sampling_count = 0;
    g_profiler.sampling_total_ns = 0;
    g_profiler.sample_capacity = SPERF_INITIAL_SAMPLES;
    g_profiler.samples = (sperf_sample_t *)calloc(
        g_profiler.sample_capacity, sizeof(sperf_sample_t));
    if (!g_profiler.samples) {
        rb_raise(rb_eNoMemError, "sperf: failed to allocate sample buffer");
    }

    g_profiler.frame_pool_count = 0;
    g_profiler.frame_pool_capacity = SPERF_INITIAL_FRAME_POOL;
    g_profiler.frame_pool = (VALUE *)calloc(
        g_profiler.frame_pool_capacity, sizeof(VALUE));
    if (!g_profiler.frame_pool) {
        free(g_profiler.samples);
        g_profiler.samples = NULL;
        rb_raise(rb_eNoMemError, "sperf: failed to allocate frame pool");
    }

    /* Register GC event hook */
    g_profiler.gc_phase = SPERF_GC_NONE;
    g_profiler.gc_frame_depth = 0;
    rb_add_event_hook(sperf_gc_event_hook,
                      RUBY_INTERNAL_EVENT_GC_START |
                      RUBY_INTERNAL_EVENT_GC_END_MARK |
                      RUBY_INTERNAL_EVENT_GC_END_SWEEP |
                      RUBY_INTERNAL_EVENT_GC_ENTER |
                      RUBY_INTERNAL_EVENT_GC_EXIT,
                      Qnil);

    /* Register thread event hook for all events */
    g_profiler.thread_hook = rb_internal_thread_add_event_hook(
        sperf_thread_event_hook,
        RUBY_INTERNAL_THREAD_EVENT_EXITED |
        RUBY_INTERNAL_THREAD_EVENT_SUSPENDED |
        RUBY_INTERNAL_THREAD_EVENT_READY |
        RUBY_INTERNAL_THREAD_EVENT_RESUMED,
        &g_profiler);

    /* Pre-initialize current thread's time so the first sample is not skipped */
    {
        VALUE cur_thread = rb_thread_current();
        sperf_thread_data_t *td = sperf_thread_data_create(&g_profiler, cur_thread);
        if (!td) {
            free(g_profiler.samples);
            g_profiler.samples = NULL;
            free(g_profiler.frame_pool);
            g_profiler.frame_pool = NULL;
            rb_internal_thread_remove_event_hook(g_profiler.thread_hook);
            g_profiler.thread_hook = NULL;
            rb_raise(rb_eNoMemError, "sperf: failed to allocate thread data");
        }
    }

    g_profiler.running = 1;

    if (pthread_create(&g_profiler.timer_thread, NULL, sperf_timer_func, &g_profiler) != 0) {
        g_profiler.running = 0;
        {
            VALUE cur = rb_thread_current();
            sperf_thread_data_t *td = (sperf_thread_data_t *)rb_internal_thread_specific_get(cur, g_profiler.ts_key);
            if (td) {
                free(td);
                rb_internal_thread_specific_set(cur, g_profiler.ts_key, NULL);
            }
        }
        rb_internal_thread_remove_event_hook(g_profiler.thread_hook);
        g_profiler.thread_hook = NULL;
        free(g_profiler.samples);
        g_profiler.samples = NULL;
        free(g_profiler.frame_pool);
        g_profiler.frame_pool = NULL;
        rb_raise(rb_eRuntimeError, "sperf: failed to create timer thread");
    }

    return Qtrue;
}

static VALUE
rb_sperf_stop(VALUE self)
{
    VALUE result, samples_ary;
    size_t i;
    int j;

    if (!g_profiler.running) {
        return Qnil;
    }

    g_profiler.running = 0;
    pthread_join(g_profiler.timer_thread, NULL);

    if (g_profiler.thread_hook) {
        rb_internal_thread_remove_event_hook(g_profiler.thread_hook);
        g_profiler.thread_hook = NULL;
    }

    /* Remove GC event hook */
    rb_remove_event_hook(sperf_gc_event_hook);

    /* Clean up thread-specific data for all live threads */
    {
        VALUE threads = rb_funcall(rb_cThread, rb_intern("list"), 0);
        long tc = RARRAY_LEN(threads);
        long ti;
        for (ti = 0; ti < tc; ti++) {
            VALUE thread = RARRAY_AREF(threads, ti);
            sperf_thread_data_t *td = (sperf_thread_data_t *)rb_internal_thread_specific_get(thread, g_profiler.ts_key);
            if (td) {
                free(td);
                rb_internal_thread_specific_set(thread, g_profiler.ts_key, NULL);
            }
        }
    }

    /* Build result hash */
    result = rb_hash_new();

    /* mode */
    rb_hash_aset(result, ID2SYM(rb_intern("mode")),
                 ID2SYM(rb_intern(g_profiler.mode == 1 ? "wall" : "cpu")));

    /* frequency */
    rb_hash_aset(result, ID2SYM(rb_intern("frequency")), INT2NUM(g_profiler.frequency));

    /* sampling_count, sampling_time_ns */
    rb_hash_aset(result, ID2SYM(rb_intern("sampling_count")), SIZET2NUM(g_profiler.sampling_count));
    rb_hash_aset(result, ID2SYM(rb_intern("sampling_time_ns")), LONG2NUM(g_profiler.sampling_total_ns));

    /* samples: array of [frames_array, weight]
     * Each frame is [path_string, label_string]
     * GVL blocked/wait samples get synthetic frame prepended (leaf position) */
    samples_ary = rb_ary_new_capa((long)g_profiler.sample_count);
    for (i = 0; i < g_profiler.sample_count; i++) {
        sperf_sample_t *s = &g_profiler.samples[i];
        VALUE frames = rb_ary_new_capa(s->depth + 1);

        /* Prepend synthetic frame at leaf position (index 0) */
        if (s->type == SPERF_SAMPLE_GVL_BLOCKED) {
            VALUE syn = rb_ary_new3(2, rb_str_new_lit("<GVL>"), rb_str_new_lit("[GVL blocked]"));
            rb_ary_push(frames, syn);
        } else if (s->type == SPERF_SAMPLE_GVL_WAIT) {
            VALUE syn = rb_ary_new3(2, rb_str_new_lit("<GVL>"), rb_str_new_lit("[GVL wait]"));
            rb_ary_push(frames, syn);
        } else if (s->type == SPERF_SAMPLE_GC_MARKING) {
            VALUE syn = rb_ary_new3(2, rb_str_new_lit("<GC>"), rb_str_new_lit("[GC marking]"));
            rb_ary_push(frames, syn);
        } else if (s->type == SPERF_SAMPLE_GC_SWEEPING) {
            VALUE syn = rb_ary_new3(2, rb_str_new_lit("<GC>"), rb_str_new_lit("[GC sweeping]"));
            rb_ary_push(frames, syn);
        }

        for (j = 0; j < s->depth; j++) {
            VALUE fval = g_profiler.frame_pool[s->frame_start + j];
            rb_ary_push(frames, sperf_resolve_frame(fval));
        }

        VALUE sample = rb_ary_new3(2, frames, LONG2NUM(s->weight));
        rb_ary_push(samples_ary, sample);
    }
    rb_hash_aset(result, ID2SYM(rb_intern("samples")), samples_ary);

    /* Cleanup */
    free(g_profiler.samples);
    g_profiler.samples = NULL;
    free(g_profiler.frame_pool);
    g_profiler.frame_pool = NULL;
    g_profiler.frame_pool_count = 0;

    return result;
}

/* ---- Init ---- */

void
Init_sperf(void)
{
    VALUE mSperf = rb_define_module("Sperf");
    rb_define_module_function(mSperf, "_c_start", rb_sperf_start, -1);
    rb_define_module_function(mSperf, "_c_stop", rb_sperf_stop, 0);

    memset(&g_profiler, 0, sizeof(g_profiler));
    g_profiler.pj_handle = rb_postponed_job_preregister(0, sperf_sample_job, &g_profiler);
    g_profiler.ts_key = rb_internal_thread_specific_key_create();

    /* TypedData wrapper for GC marking of frame_pool */
    g_profiler_wrapper = TypedData_Wrap_Struct(rb_cObject, &sperf_profiler_type, &g_profiler);
    rb_gc_register_address(&g_profiler_wrapper);
}
