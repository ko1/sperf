#include <ruby.h>
#include <ruby/debug.h>
#include <ruby/thread.h>
#include <ruby/internal/intern/thread.h>
#include <pthread.h>
#include <time.h>
#include <string.h>
#include <stdlib.h>

#define SPROF_MAX_STACK_DEPTH 512
#define SPROF_INITIAL_SAMPLES 1024
#define SPROF_INITIAL_STRINGS 256

/* ---- Data structures ---- */

typedef struct sprof_frame_key {
    int path_idx;
    int label_idx;
    int lineno;
} sprof_frame_key_t;

typedef struct sprof_sample {
    int depth;
    sprof_frame_key_t frames[SPROF_MAX_STACK_DEPTH];
    int64_t weight;
} sprof_sample_t;

typedef struct sprof_string_table {
    char **strings;
    size_t count;
    size_t capacity;
    st_table *hash;
} sprof_string_table_t;

typedef struct sprof_thread_data {
    int64_t prev_cpu_ns;
} sprof_thread_data_t;

typedef struct sprof_profiler {
    int frequency;
    int mode; /* 0 = cpu, 1 = wall */
    volatile int running;
    pthread_t timer_thread;
    rb_postponed_job_handle_t pj_handle;
    sprof_sample_t *samples;
    size_t sample_count;
    size_t sample_capacity;
    sprof_string_table_t string_table;
    rb_internal_thread_specific_key_t ts_key;
    rb_internal_thread_event_hook_t *thread_hook;
    /* Sampling overhead stats */
    size_t sampling_count;
    int64_t sampling_total_ns;
} sprof_profiler_t;

static sprof_profiler_t g_profiler;
static ID id_list, id_native_thread_id;

/* ---- String table ---- */

static void
sprof_string_table_init(sprof_string_table_t *st)
{
    st->capacity = SPROF_INITIAL_STRINGS;
    st->count = 0;
    st->strings = (char **)calloc(st->capacity, sizeof(char *));
    st->hash = st_init_strtable();

    /* Index 0 must be empty string for pprof */
    st->strings[0] = strdup("");
    st_insert(st->hash, (st_data_t)st->strings[0], (st_data_t)0);
    st->count = 1;
}

static int
sprof_string_table_intern(sprof_string_table_t *st, const char *str)
{
    st_data_t idx;

    if (str == NULL) str = "";

    if (st_lookup(st->hash, (st_data_t)str, &idx)) {
        return (int)idx;
    }

    if (st->count >= st->capacity) {
        st->capacity *= 2;
        st->strings = (char **)realloc(st->strings, st->capacity * sizeof(char *));
    }

    idx = (st_data_t)st->count;
    st->strings[st->count] = strdup(str);
    st_insert(st->hash, (st_data_t)st->strings[st->count], idx);
    st->count++;

    return (int)idx;
}

static void
sprof_string_table_free(sprof_string_table_t *st)
{
    size_t i;
    for (i = 0; i < st->count; i++) {
        free(st->strings[i]);
    }
    free(st->strings);
    st->strings = NULL;
    if (st->hash) {
        st_free_table(st->hash);
        st->hash = NULL;
    }
    st->count = 0;
    st->capacity = 0;
}

/* ---- CPU time ---- */

static int64_t
sprof_cpu_time_ns(pid_t tid)
{
    /* Linux kernel ABI: thread CPU clock from TID */
    clockid_t cid = ~(clockid_t)(tid) << 3 | 6;
    struct timespec ts;
    if (clock_gettime(cid, &ts) != 0) return -1;
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ---- Wall time ---- */

static int64_t
sprof_wall_time_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ---- Sample buffer ---- */

static void
sprof_ensure_sample_capacity(sprof_profiler_t *prof)
{
    if (prof->sample_count >= prof->sample_capacity) {
        prof->sample_capacity *= 2;
        prof->samples = (sprof_sample_t *)realloc(
            prof->samples,
            prof->sample_capacity * sizeof(sprof_sample_t));
    }
}

/* ---- Thread event hook ---- */

static void
sprof_thread_exit_hook(rb_event_flag_t event, const rb_internal_thread_event_data_t *data, void *user_data)
{
    sprof_profiler_t *prof = (sprof_profiler_t *)user_data;
    VALUE thread = data->thread;
    sprof_thread_data_t *td = (sprof_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);
    if (td) {
        free(td);
        rb_internal_thread_specific_set(thread, prof->ts_key, NULL);
    }
}

/* ---- Sampling callback (postponed job) ---- */

static void
sprof_sample_job(void *arg)
{
    sprof_profiler_t *prof = (sprof_profiler_t *)arg;
    VALUE threads, thread;
    long i, thread_count;
    VALUE frame_buf[SPROF_MAX_STACK_DEPTH];
    int line_buf[SPROF_MAX_STACK_DEPTH];

    if (!prof->running) return;

    /* Measure sampling overhead */
    struct timespec ts_start, ts_end;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts_start);

    /* For wall mode, get wall time once (shared across all threads) */
    int64_t wall_now = 0;
    if (prof->mode == 1) {
        wall_now = sprof_wall_time_ns();
    }

    threads = rb_funcall(rb_cThread, id_list, 0);
    thread_count = RARRAY_LEN(threads);

    for (i = 0; i < thread_count; i++) {
        thread = RARRAY_AREF(threads, i);

        int64_t time_now;

        if (prof->mode == 0) {
            /* CPU mode: per-thread CPU time */
            VALUE tid_val = rb_funcall(thread, id_native_thread_id, 0);
            if (NIL_P(tid_val)) continue;
            pid_t tid = (pid_t)NUM2INT(tid_val);
            time_now = sprof_cpu_time_ns(tid);
            if (time_now < 0) continue;
        } else {
            /* Wall mode: monotonic clock */
            time_now = wall_now;
        }

        /* Get/create per-thread data */
        sprof_thread_data_t *td = (sprof_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);
        if (td == NULL) {
            td = (sprof_thread_data_t *)calloc(1, sizeof(sprof_thread_data_t));
            rb_internal_thread_specific_set(thread, prof->ts_key, td);
            td->prev_cpu_ns = time_now;
            continue; /* Skip first sample for this thread */
        }

        int64_t weight = time_now - td->prev_cpu_ns;
        td->prev_cpu_ns = time_now;

        if (weight <= 0) continue;

        /* Get backtrace */
        int depth = rb_profile_thread_frames(thread, 0, SPROF_MAX_STACK_DEPTH, frame_buf, line_buf);
        if (depth <= 0) continue;

        /* Record sample */
        sprof_ensure_sample_capacity(prof);
        sprof_sample_t *sample = &prof->samples[prof->sample_count];
        sample->depth = depth;
        sample->weight = weight;

        int j;
        for (j = 0; j < depth; j++) {
            VALUE path = rb_profile_frame_path(frame_buf[j]);
            VALUE label = rb_profile_frame_label(frame_buf[j]);

            /* Fallback for C methods: label/path are Qnil since there is no iseq */
            if (NIL_P(label)) label = rb_profile_frame_method_name(frame_buf[j]);
            if (NIL_P(path))  path  = rb_profile_frame_classpath(frame_buf[j]);

            const char *path_str = NIL_P(path) ? "" : StringValueCStr(path);
            const char *label_str = NIL_P(label) ? "" : StringValueCStr(label);

            sample->frames[j].path_idx = sprof_string_table_intern(&prof->string_table, path_str);
            sample->frames[j].label_idx = sprof_string_table_intern(&prof->string_table, label_str);
            sample->frames[j].lineno = line_buf[j];
        }

        prof->sample_count++;
    }

    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts_end);
    prof->sampling_count++;
    prof->sampling_total_ns +=
        ((int64_t)ts_end.tv_sec - ts_start.tv_sec) * 1000000000LL +
        (ts_end.tv_nsec - ts_start.tv_nsec);
}

/* ---- Timer thread ---- */

static void *
sprof_timer_func(void *arg)
{
    sprof_profiler_t *prof = (sprof_profiler_t *)arg;
    struct timespec interval;
    interval.tv_sec = 0;
    interval.tv_nsec = 1000000000L / prof->frequency;

    while (prof->running) {
        rb_postponed_job_trigger(prof->pj_handle);
        nanosleep(&interval, NULL);
    }
    return NULL;
}

/* ---- Ruby API ---- */

static VALUE
rb_sprof_start(int argc, VALUE *argv, VALUE self)
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
        rb_raise(rb_eRuntimeError, "Sprof is already running");
    }

    g_profiler.frequency = frequency;
    g_profiler.mode = mode;
    g_profiler.sample_count = 0;
    g_profiler.sampling_count = 0;
    g_profiler.sampling_total_ns = 0;
    g_profiler.sample_capacity = SPROF_INITIAL_SAMPLES;
    g_profiler.samples = (sprof_sample_t *)calloc(
        g_profiler.sample_capacity, sizeof(sprof_sample_t));

    sprof_string_table_init(&g_profiler.string_table);

    /* Register thread exit hook */
    g_profiler.thread_hook = rb_internal_thread_add_event_hook(
        sprof_thread_exit_hook,
        RUBY_INTERNAL_THREAD_EVENT_EXITED,
        &g_profiler);

    /* Pre-initialize current thread's time so the first sample is not skipped */
    {
        VALUE cur_thread = rb_thread_current();
        int64_t init_time = -1;
        if (g_profiler.mode == 1) {
            init_time = sprof_wall_time_ns();
        } else {
            VALUE tid_val = rb_funcall(cur_thread, id_native_thread_id, 0);
            if (!NIL_P(tid_val)) {
                pid_t tid = (pid_t)NUM2INT(tid_val);
                init_time = sprof_cpu_time_ns(tid);
            }
        }
        if (init_time >= 0) {
            sprof_thread_data_t *td = (sprof_thread_data_t *)calloc(1, sizeof(sprof_thread_data_t));
            td->prev_cpu_ns = init_time;
            rb_internal_thread_specific_set(cur_thread, g_profiler.ts_key, td);
        }
    }

    g_profiler.running = 1;

    pthread_create(&g_profiler.timer_thread, NULL, sprof_timer_func, &g_profiler);

    return Qtrue;
}

static VALUE
rb_sprof_stop(VALUE self)
{
    VALUE result, string_table_ary, samples_ary;
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

    /* Clean up thread-specific data for all live threads */
    {
        VALUE threads = rb_funcall(rb_cThread, id_list, 0);
        long tc = RARRAY_LEN(threads);
        long ti;
        for (ti = 0; ti < tc; ti++) {
            VALUE thread = RARRAY_AREF(threads, ti);
            sprof_thread_data_t *td = (sprof_thread_data_t *)rb_internal_thread_specific_get(thread, g_profiler.ts_key);
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

    /* string_table */
    string_table_ary = rb_ary_new_capa((long)g_profiler.string_table.count);
    for (i = 0; i < g_profiler.string_table.count; i++) {
        rb_ary_push(string_table_ary, rb_str_new_cstr(g_profiler.string_table.strings[i]));
    }
    rb_hash_aset(result, ID2SYM(rb_intern("string_table")), string_table_ary);

    /* samples: array of [frames_array, weight] */
    samples_ary = rb_ary_new_capa((long)g_profiler.sample_count);
    for (i = 0; i < g_profiler.sample_count; i++) {
        sprof_sample_t *s = &g_profiler.samples[i];
        VALUE frames = rb_ary_new_capa(s->depth);
        for (j = 0; j < s->depth; j++) {
            VALUE frame = rb_ary_new3(3,
                INT2NUM(s->frames[j].path_idx),
                INT2NUM(s->frames[j].label_idx),
                INT2NUM(s->frames[j].lineno));
            rb_ary_push(frames, frame);
        }
        VALUE sample = rb_ary_new3(2, frames, LONG2NUM(s->weight));
        rb_ary_push(samples_ary, sample);
    }
    rb_hash_aset(result, ID2SYM(rb_intern("samples")), samples_ary);

    /* Cleanup */
    free(g_profiler.samples);
    g_profiler.samples = NULL;
    sprof_string_table_free(&g_profiler.string_table);

    return result;
}

/* ---- Init ---- */

void
Init_sprof(void)
{
    VALUE mSprof = rb_define_module("Sprof");
    rb_define_module_function(mSprof, "start", rb_sprof_start, -1);
    rb_define_module_function(mSprof, "stop", rb_sprof_stop, 0);

    id_list = rb_intern("list");
    id_native_thread_id = rb_intern("native_thread_id");

    memset(&g_profiler, 0, sizeof(g_profiler));
    g_profiler.pj_handle = rb_postponed_job_preregister(0, sprof_sample_job, &g_profiler);
    g_profiler.ts_key = rb_internal_thread_specific_key_create();
}
