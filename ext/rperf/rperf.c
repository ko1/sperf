#include <ruby.h>
#include <ruby/debug.h>
#include <ruby/thread.h>
#include <pthread.h>
#include <time.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <assert.h>
#include <stdatomic.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif

/* Checked pthread wrappers — assert on unexpected errors */
#define CHECKED(call) do { int _r = (call); assert(_r == 0 && #call); (void)_r; } while (0)

#ifdef __linux__
#define RPERF_USE_TIMER_SIGNAL 1
#define RPERF_TIMER_SIGNAL_DEFAULT (SIGRTMIN + 8)
#else
#define RPERF_USE_TIMER_SIGNAL 0
#endif

#define RPERF_MAX_STACK_DEPTH 512
#define RPERF_INITIAL_SAMPLES 16384  /* >= AGG_THRESHOLD to avoid realloc before first aggregation */
#define RPERF_INITIAL_FRAME_POOL (1024 * 1024 / sizeof(VALUE)) /* ~1MB */
#define RPERF_AGG_THRESHOLD 10000  /* aggregate every N samples */
#define RPERF_FRAME_TABLE_INITIAL 4096
#define RPERF_FRAME_TABLE_OLD_KEYS_MAX 16  /* max number of old keys arrays kept until stop */
#define RPERF_AGG_TABLE_INITIAL 1024
#define RPERF_STACK_POOL_INITIAL 4096

/* Synthetic frame IDs (reserved in frame_table, 0-based) */
#define RPERF_SYNTHETIC_GVL_BLOCKED 0
#define RPERF_SYNTHETIC_GVL_WAIT    1
#define RPERF_SYNTHETIC_GC_MARKING  2
#define RPERF_SYNTHETIC_GC_SWEEPING 3
#define RPERF_SYNTHETIC_COUNT       4

/* ---- Data structures ---- */

enum rperf_sample_type {
    RPERF_SAMPLE_NORMAL      = 0,
    RPERF_SAMPLE_GVL_BLOCKED = 1,  /* off-GVL: SUSPENDED → READY */
    RPERF_SAMPLE_GVL_WAIT    = 2,  /* GVL wait: READY → RESUMED */
    RPERF_SAMPLE_GC_MARKING  = 3,  /* GC marking phase */
    RPERF_SAMPLE_GC_SWEEPING = 4,  /* GC sweeping phase */
};

enum rperf_gc_phase {
    RPERF_GC_NONE     = 0,
    RPERF_GC_MARKING  = 1,
    RPERF_GC_SWEEPING = 2,
};

typedef struct rperf_sample {
    int depth;
    size_t frame_start; /* index into frame_pool */
    int64_t weight;
    int type;           /* rperf_sample_type */
    int thread_seq;     /* thread sequence number (1-based) */
} rperf_sample_t;

/* ---- Sample buffer (double-buffered) ---- */

typedef struct rperf_sample_buffer {
    rperf_sample_t *samples;
    size_t sample_count;
    size_t sample_capacity;
    VALUE *frame_pool;
    size_t frame_pool_count;
    size_t frame_pool_capacity;
} rperf_sample_buffer_t;

/* ---- Frame table: VALUE → uint32_t frame_id ---- */

#define RPERF_FRAME_TABLE_EMPTY UINT32_MAX

typedef struct rperf_frame_table {
    _Atomic(VALUE *) keys;    /* unique VALUE array (GC mark target) */
    size_t count;             /* = next frame_id (starts after RPERF_SYNTHETIC_COUNT) */
    size_t capacity;
    uint32_t *buckets;        /* open addressing: stores index into keys[] */
    size_t bucket_capacity;
    /* Old keys arrays kept alive for GC dmark safety until stop */
    VALUE *old_keys[RPERF_FRAME_TABLE_OLD_KEYS_MAX];
    int old_keys_count;
} rperf_frame_table_t;

/* ---- Aggregation table: stack → weight ---- */

#define RPERF_AGG_ENTRY_EMPTY 0

typedef struct rperf_agg_entry {
    uint32_t frame_start;     /* offset into stack_pool */
    int depth;                /* includes synthetic frame */
    int thread_seq;
    int64_t weight;           /* accumulated */
    uint32_t hash;            /* cached hash value */
    int used;                 /* 0 = empty, 1 = used */
} rperf_agg_entry_t;

typedef struct rperf_agg_table {
    rperf_agg_entry_t *buckets;
    size_t bucket_capacity;
    size_t count;
    uint32_t *stack_pool;     /* frame_id sequences stored contiguously */
    size_t stack_pool_count;
    size_t stack_pool_capacity;
} rperf_agg_table_t;

typedef struct rperf_thread_data {
    int64_t prev_time_ns;
    int64_t prev_wall_ns;
    /* GVL event tracking */
    int64_t suspended_at_ns;        /* wall time at SUSPENDED */
    int64_t ready_at_ns;            /* wall time at READY */
    size_t suspended_frame_start;   /* saved stack in frame_pool */
    int suspended_frame_depth;      /* saved stack depth */
    int thread_seq;                 /* thread sequence number (1-based) */
} rperf_thread_data_t;

/* ---- GC tracking state ---- */

typedef struct rperf_gc_state {
    int phase;                /* rperf_gc_phase */
    int64_t enter_ns;         /* wall time at GC_ENTER */
    size_t frame_start;       /* saved stack at GC_ENTER */
    int frame_depth;          /* saved stack depth */
    int thread_seq;           /* thread_seq at GC_ENTER */
} rperf_gc_state_t;

/* ---- Sampling overhead stats ---- */

typedef struct rperf_stats {
    size_t trigger_count;
    size_t sampling_count;
    int64_t sampling_total_ns;
} rperf_stats_t;

typedef struct rperf_profiler {
    int frequency;
    int mode; /* 0 = cpu, 1 = wall */
    _Atomic int running;
    pthread_t worker_thread;     /* combined timer + aggregation */
#if RPERF_USE_TIMER_SIGNAL
    timer_t timer_id;
    int timer_signal;     /* >0: use timer signal, 0: use nanosleep thread */
    _Atomic pid_t worker_tid;    /* kernel TID of worker thread (for SIGEV_THREAD_ID) */
    struct sigaction old_sigaction;  /* saved handler to restore on stop */
#endif
    rb_postponed_job_handle_t pj_handle;
    int aggregate;               /* 1 = aggregate samples, 0 = raw */
    /* Double-buffered sample storage (only buffers[0] used when !aggregate) */
    rperf_sample_buffer_t buffers[2];
    _Atomic int active_idx;      /* 0 or 1 */
    /* Aggregation (only used when aggregate=1) */
    rperf_frame_table_t frame_table;
    rperf_agg_table_t agg_table;
    _Atomic int swap_ready;      /* 1 = standby buffer ready for aggregation */
    pthread_mutex_t worker_mutex;
    pthread_cond_t worker_cond;
    rb_internal_thread_specific_key_t ts_key;
    rb_internal_thread_event_hook_t *thread_hook;
    /* GC tracking */
    rperf_gc_state_t gc;
    /* Timing metadata for pprof */
    struct timespec start_realtime;   /* CLOCK_REALTIME at start */
    struct timespec start_monotonic;  /* CLOCK_MONOTONIC at start */
    /* Thread sequence counter */
    int next_thread_seq;
    /* Sampling overhead stats */
    rperf_stats_t stats;
} rperf_profiler_t;

static rperf_profiler_t g_profiler;
static VALUE g_profiler_wrapper = Qnil;

/* ---- TypedData for GC marking of frame_pool ---- */

static void
rperf_profiler_mark(void *ptr)
{
    rperf_profiler_t *prof = (rperf_profiler_t *)ptr;
    int i;
    /* Mark both sample buffers' frame_pools */
    for (i = 0; i < 2; i++) {
        rperf_sample_buffer_t *buf = &prof->buffers[i];
        if (buf->frame_pool && buf->frame_pool_count > 0) {
            rb_gc_mark_locations(buf->frame_pool,
                                buf->frame_pool + buf->frame_pool_count);
        }
    }
    /* Mark frame_table keys (unique frame VALUEs).
     * Acquire count to synchronize with the release-store in insert,
     * ensuring we see the keys pointer that is valid for [0, count).
     * If we see an old count, both old and new keys arrays have valid
     * data (old keys are kept alive in old_keys[]). */
    {
        size_t ft_count = __atomic_load_n(&prof->frame_table.count, __ATOMIC_ACQUIRE);
        VALUE *ft_keys = atomic_load_explicit(&prof->frame_table.keys, memory_order_acquire);
        if (ft_keys && ft_count > 0) {
            rb_gc_mark_locations(ft_keys + RPERF_SYNTHETIC_COUNT,
                                ft_keys + ft_count);
        }
    }
}

static const rb_data_type_t rperf_profiler_type = {
    .wrap_struct_name = "rperf_profiler",
    .function = {
        .dmark = rperf_profiler_mark,
        .dfree = NULL,
        .dsize = NULL,
    },
};

/* ---- CPU time ---- */

static int64_t
rperf_cpu_time_ns(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) return -1;
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ---- Wall time ---- */

static int64_t
rperf_wall_time_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ---- Get current thread's time based on profiler mode ---- */

static int64_t
rperf_current_time_ns(rperf_profiler_t *prof, rperf_thread_data_t *td)
{
    if (prof->mode == 0) {
        return rperf_cpu_time_ns();
    } else {
        return rperf_wall_time_ns();
    }
}

/* ---- Sample buffer ---- */

static int
rperf_sample_buffer_init(rperf_sample_buffer_t *buf)
{
    buf->sample_count = 0;
    buf->sample_capacity = RPERF_INITIAL_SAMPLES;
    buf->samples = (rperf_sample_t *)calloc(buf->sample_capacity, sizeof(rperf_sample_t));
    if (!buf->samples) return -1;

    buf->frame_pool_count = 0;
    buf->frame_pool_capacity = RPERF_INITIAL_FRAME_POOL;
    buf->frame_pool = (VALUE *)calloc(buf->frame_pool_capacity, sizeof(VALUE));
    if (!buf->frame_pool) {
        free(buf->samples);
        buf->samples = NULL;
        return -1;
    }
    return 0;
}

static void
rperf_sample_buffer_free(rperf_sample_buffer_t *buf)
{
    free(buf->samples);
    free(buf->frame_pool);
    memset(buf, 0, sizeof(*buf));
}

/* Returns 0 on success, -1 on allocation failure */
static int
rperf_ensure_sample_capacity(rperf_sample_buffer_t *buf)
{
    if (buf->sample_count >= buf->sample_capacity) {
        size_t new_cap = buf->sample_capacity * 2;
        rperf_sample_t *new_samples = (rperf_sample_t *)realloc(
            buf->samples,
            new_cap * sizeof(rperf_sample_t));
        if (!new_samples) return -1;
        buf->samples = new_samples;
        buf->sample_capacity = new_cap;
    }
    return 0;
}

/* ---- Frame pool ---- */

/* Ensure frame_pool has room for `needed` more entries. Returns 0 on success. */
static int
rperf_ensure_frame_pool_capacity(rperf_sample_buffer_t *buf, int needed)
{
    while (buf->frame_pool_count + (size_t)needed > buf->frame_pool_capacity) {
        size_t new_cap = buf->frame_pool_capacity * 2;
        VALUE *new_pool = (VALUE *)realloc(
            buf->frame_pool,
            new_cap * sizeof(VALUE));
        if (!new_pool) return -1;
        buf->frame_pool = new_pool;
        buf->frame_pool_capacity = new_cap;
    }
    return 0;
}

/* ---- Frame table operations (all malloc-based, no GVL needed) ---- */

static int
rperf_frame_table_init(rperf_frame_table_t *ft)
{
    ft->capacity = RPERF_FRAME_TABLE_INITIAL;
    VALUE *keys = (VALUE *)calloc(ft->capacity, sizeof(VALUE));
    if (!keys) return -1;
    atomic_store_explicit(&ft->keys, keys, memory_order_relaxed);
    ft->count = RPERF_SYNTHETIC_COUNT; /* reserve slots for synthetic frames */
    ft->bucket_capacity = RPERF_FRAME_TABLE_INITIAL * 2;
    ft->buckets = (uint32_t *)malloc(ft->bucket_capacity * sizeof(uint32_t));
    if (!ft->buckets) { free(keys); atomic_store_explicit(&ft->keys, NULL, memory_order_relaxed); return -1; }
    memset(ft->buckets, 0xFF, ft->bucket_capacity * sizeof(uint32_t)); /* EMPTY */
    ft->old_keys_count = 0;
    return 0;
}

static void
rperf_frame_table_free(rperf_frame_table_t *ft)
{
    int i;
    for (i = 0; i < ft->old_keys_count; i++)
        free(ft->old_keys[i]);
    free(atomic_load_explicit(&ft->keys, memory_order_relaxed));
    free(ft->buckets);
    memset(ft, 0, sizeof(*ft));
}

static void
rperf_frame_table_rehash(rperf_frame_table_t *ft)
{
    size_t new_cap = ft->bucket_capacity * 2;
    uint32_t *new_buckets = (uint32_t *)malloc(new_cap * sizeof(uint32_t));
    if (!new_buckets) return; /* keep using current buckets at higher load factor */
    memset(new_buckets, 0xFF, new_cap * sizeof(uint32_t));

    VALUE *keys = atomic_load_explicit(&ft->keys, memory_order_relaxed);
    size_t i;
    for (i = RPERF_SYNTHETIC_COUNT; i < ft->count; i++) {
        uint32_t h = (uint32_t)(keys[i] >> 3); /* shift out tag bits */
        size_t idx = h % new_cap;
        while (new_buckets[idx] != RPERF_FRAME_TABLE_EMPTY)
            idx = (idx + 1) % new_cap;
        new_buckets[idx] = (uint32_t)i;
    }

    free(ft->buckets);
    ft->buckets = new_buckets;
    ft->bucket_capacity = new_cap;
}

/* Returns frame_id for the given VALUE, inserting if new */
static uint32_t
rperf_frame_table_insert(rperf_frame_table_t *ft, VALUE fval)
{
    VALUE *keys = atomic_load_explicit(&ft->keys, memory_order_relaxed);
    uint32_t h = (uint32_t)(fval >> 3);
    size_t idx = h % ft->bucket_capacity;

    while (1) {
        uint32_t slot = ft->buckets[idx];
        if (slot == RPERF_FRAME_TABLE_EMPTY) break;
        if (keys[slot] == fval) return slot;
        idx = (idx + 1) % ft->bucket_capacity;
    }

    /* Insert new entry.  Grow keys array if capacity is exhausted.
     * Cannot realloc in-place because GC dmark may concurrently read
     * the old keys pointer.  Instead, allocate new, copy, swap pointer
     * atomically, and keep old array alive until stop. */
    if (ft->count >= ft->capacity) {
        size_t new_cap = ft->capacity * 2;
        VALUE *new_keys = (VALUE *)calloc(new_cap, sizeof(VALUE));
        if (!new_keys) return RPERF_FRAME_TABLE_EMPTY;
        memcpy(new_keys, keys, ft->capacity * sizeof(VALUE));
        /* Save old keys for deferred free (GC dmark safety) */
        if (ft->old_keys_count < RPERF_FRAME_TABLE_OLD_KEYS_MAX)
            ft->old_keys[ft->old_keys_count++] = keys;
        else
            free(keys); /* unlikely: >16 doublings */
        keys = new_keys;
        atomic_store_explicit(&ft->keys, new_keys, memory_order_release);
        ft->capacity = new_cap;
    }

    uint32_t frame_id = (uint32_t)ft->count;
    keys[frame_id] = fval;
    /* Store fence: ensure keys[frame_id] is visible before count is incremented,
     * so GC dmark never reads uninitialized keys[count-1]. */
    __atomic_store_n(&ft->count, ft->count + 1, __ATOMIC_RELEASE);
    ft->buckets[idx] = frame_id;

    /* Rehash if load factor > 0.7 */
    if (ft->count * 10 > ft->bucket_capacity * 7) {
        rperf_frame_table_rehash(ft);
    }

    return frame_id;
}

/* ---- Aggregation table operations (all malloc-based, no GVL needed) ---- */

static uint32_t
rperf_fnv1a_u32(const uint32_t *data, int len, int thread_seq)
{
    uint32_t h = 2166136261u;
    int i;
    for (i = 0; i < len; i++) {
        h ^= data[i];
        h *= 16777619u;
    }
    h ^= (uint32_t)thread_seq;
    h *= 16777619u;
    return h;
}

static int
rperf_agg_table_init(rperf_agg_table_t *at)
{
    at->bucket_capacity = RPERF_AGG_TABLE_INITIAL * 2;
    at->buckets = (rperf_agg_entry_t *)calloc(at->bucket_capacity, sizeof(rperf_agg_entry_t));
    if (!at->buckets) return -1;
    at->count = 0;
    at->stack_pool_capacity = RPERF_STACK_POOL_INITIAL;
    at->stack_pool = (uint32_t *)malloc(at->stack_pool_capacity * sizeof(uint32_t));
    if (!at->stack_pool) { free(at->buckets); at->buckets = NULL; return -1; }
    at->stack_pool_count = 0;
    return 0;
}

static void
rperf_agg_table_free(rperf_agg_table_t *at)
{
    free(at->buckets);
    free(at->stack_pool);
    memset(at, 0, sizeof(*at));
}

static void
rperf_agg_table_rehash(rperf_agg_table_t *at)
{
    size_t new_cap = at->bucket_capacity * 2;
    rperf_agg_entry_t *new_buckets = (rperf_agg_entry_t *)calloc(new_cap, sizeof(rperf_agg_entry_t));
    if (!new_buckets) return; /* keep using current buckets at higher load factor */

    size_t i;
    for (i = 0; i < at->bucket_capacity; i++) {
        if (!at->buckets[i].used) continue;
        rperf_agg_entry_t *e = &at->buckets[i];
        size_t idx = e->hash % new_cap;
        while (new_buckets[idx].used)
            idx = (idx + 1) % new_cap;
        new_buckets[idx] = *e;
    }

    free(at->buckets);
    at->buckets = new_buckets;
    at->bucket_capacity = new_cap;
}

/* Ensure stack_pool has room for `needed` more entries */
static int
rperf_agg_ensure_stack_pool(rperf_agg_table_t *at, int needed)
{
    while (at->stack_pool_count + (size_t)needed > at->stack_pool_capacity) {
        size_t new_cap = at->stack_pool_capacity * 2;
        uint32_t *new_pool = (uint32_t *)realloc(at->stack_pool,
                                                  new_cap * sizeof(uint32_t));
        if (!new_pool) return -1;
        at->stack_pool = new_pool;
        at->stack_pool_capacity = new_cap;
    }
    return 0;
}

/* Insert or merge a stack into the aggregation table */
static void
rperf_agg_table_insert(rperf_agg_table_t *at, const uint32_t *frame_ids,
                       int depth, int thread_seq, int64_t weight, uint32_t hash)
{
    size_t idx = hash % at->bucket_capacity;

    while (1) {
        rperf_agg_entry_t *e = &at->buckets[idx];
        if (!e->used) break;
        if (e->hash == hash && e->depth == depth && e->thread_seq == thread_seq &&
            memcmp(at->stack_pool + e->frame_start, frame_ids,
                   depth * sizeof(uint32_t)) == 0) {
            /* Match — merge weight */
            e->weight += weight;
            return;
        }
        idx = (idx + 1) % at->bucket_capacity;
    }

    /* New entry — append frame_ids to stack_pool */
    if (rperf_agg_ensure_stack_pool(at, depth) < 0) return;

    rperf_agg_entry_t *e = &at->buckets[idx];
    e->frame_start = (uint32_t)at->stack_pool_count;
    e->depth = depth;
    e->thread_seq = thread_seq;
    e->weight = weight;
    e->hash = hash;
    e->used = 1;

    memcpy(at->stack_pool + at->stack_pool_count, frame_ids,
           depth * sizeof(uint32_t));
    at->stack_pool_count += depth;
    at->count++;

    /* Rehash if load factor > 0.7 */
    if (at->count * 10 > at->bucket_capacity * 7) {
        rperf_agg_table_rehash(at);
    }
}

/* ---- Aggregation: process a sample buffer into frame_table + agg_table ---- */

static void
rperf_aggregate_buffer(rperf_profiler_t *prof, rperf_sample_buffer_t *buf)
{
    size_t i;
    uint32_t temp_ids[RPERF_MAX_STACK_DEPTH + 1];

    for (i = 0; i < buf->sample_count; i++) {
        rperf_sample_t *s = &buf->samples[i];
        int off = 0;
        uint32_t hash;
        int j;

        /* Prepend synthetic frame if needed */
        if (s->type == RPERF_SAMPLE_GVL_BLOCKED) {
            temp_ids[off++] = RPERF_SYNTHETIC_GVL_BLOCKED;
        } else if (s->type == RPERF_SAMPLE_GVL_WAIT) {
            temp_ids[off++] = RPERF_SYNTHETIC_GVL_WAIT;
        } else if (s->type == RPERF_SAMPLE_GC_MARKING) {
            temp_ids[off++] = RPERF_SYNTHETIC_GC_MARKING;
        } else if (s->type == RPERF_SAMPLE_GC_SWEEPING) {
            temp_ids[off++] = RPERF_SYNTHETIC_GC_SWEEPING;
        }

        /* Convert VALUE frames to frame_ids */
        int overflow = 0;
        for (j = 0; j < s->depth; j++) {
            VALUE fval = buf->frame_pool[s->frame_start + j];
            uint32_t fid = rperf_frame_table_insert(&prof->frame_table, fval);
            if (fid == RPERF_FRAME_TABLE_EMPTY) { overflow = 1; break; }
            temp_ids[off + j] = fid;
        }
        if (overflow) break; /* frame_table full, stop aggregating this buffer */

        int total_depth = off + s->depth;
        hash = rperf_fnv1a_u32(temp_ids, total_depth, s->thread_seq);

        rperf_agg_table_insert(&prof->agg_table, temp_ids, total_depth,
                               s->thread_seq, s->weight, hash);
    }

    /* Reset buffer for reuse.
     * Release fence: ensure all frame_table inserts are visible (to GC dmark)
     * before frame_pool_count is cleared, so dmark always has at least one
     * source (frame_table or frame_pool) covering each VALUE. */
    __atomic_thread_fence(__ATOMIC_RELEASE);
    buf->sample_count = 0;
    buf->frame_pool_count = 0;
}

/* ---- Aggregation thread ---- */

/* Try to aggregate the standby buffer if swap_ready is set.
 * Called from worker thread (with or without worker_mutex held). */
static void
rperf_try_aggregate(rperf_profiler_t *prof)
{
    if (!prof->aggregate || !atomic_load_explicit(&prof->swap_ready, memory_order_acquire)) return;
    int standby_idx = atomic_load_explicit(&prof->active_idx, memory_order_acquire) ^ 1;
    rperf_aggregate_buffer(prof, &prof->buffers[standby_idx]);
    atomic_store_explicit(&prof->swap_ready, 0, memory_order_release);
}

/* ---- Record a sample ---- */

static void
rperf_try_swap(rperf_profiler_t *prof)
{
    if (!prof->aggregate) return;
    int idx = atomic_load_explicit(&prof->active_idx, memory_order_relaxed);
    rperf_sample_buffer_t *buf = &prof->buffers[idx];
    if (buf->sample_count < RPERF_AGG_THRESHOLD) return;
    if (atomic_load_explicit(&prof->swap_ready, memory_order_acquire)) return; /* standby still being aggregated */

    /* Swap active buffer: release ensures buffer writes are visible to worker */
    atomic_store_explicit(&prof->active_idx, idx ^ 1, memory_order_release);
    atomic_store_explicit(&prof->swap_ready, 1, memory_order_release);

    /* Wake worker thread */
    CHECKED(pthread_cond_signal(&prof->worker_cond));
}

static void
rperf_record_sample(rperf_profiler_t *prof, size_t frame_start, int depth,
                    int64_t weight, int type, int thread_seq)
{
    if (weight <= 0) return;
    rperf_sample_buffer_t *buf = &prof->buffers[atomic_load_explicit(&prof->active_idx, memory_order_relaxed)];
    if (rperf_ensure_sample_capacity(buf) < 0) return;

    rperf_sample_t *sample = &buf->samples[buf->sample_count];
    sample->depth = depth;
    sample->frame_start = frame_start;
    sample->weight = weight;
    sample->type = type;
    sample->thread_seq = thread_seq;
    buf->sample_count++;

    rperf_try_swap(prof);
}

/* ---- Thread data initialization ---- */

/* Create and initialize per-thread data. Must be called on the target thread. */
static rperf_thread_data_t *
rperf_thread_data_create(rperf_profiler_t *prof, VALUE thread)
{
    rperf_thread_data_t *td = (rperf_thread_data_t *)calloc(1, sizeof(rperf_thread_data_t));
    if (!td) return NULL;
    td->prev_time_ns = rperf_current_time_ns(prof, td);
    td->prev_wall_ns = rperf_wall_time_ns();
    td->thread_seq = ++prof->next_thread_seq;
    rb_internal_thread_specific_set(thread, prof->ts_key, td);
    return td;
}

/* ---- Thread event hooks ---- */

static void
rperf_handle_suspended(rperf_profiler_t *prof, VALUE thread)
{
    /* Has GVL — safe to call Ruby APIs */
    int64_t wall_now = rperf_wall_time_ns();

    rperf_thread_data_t *td = (rperf_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);
    int is_first = 0;

    if (td == NULL) {
        td = rperf_thread_data_create(prof, thread);
        if (!td) return;
        is_first = 1;
    }

    int64_t time_now = rperf_current_time_ns(prof, td);
    if (time_now < 0) return;

    /* Capture backtrace into active buffer's frame_pool */
    rperf_sample_buffer_t *buf = &prof->buffers[atomic_load_explicit(&prof->active_idx, memory_order_relaxed)];
    if (rperf_ensure_frame_pool_capacity(buf, RPERF_MAX_STACK_DEPTH) < 0) return;
    size_t frame_start = buf->frame_pool_count;
    int depth = rb_profile_frames(0, RPERF_MAX_STACK_DEPTH,
                                  &buf->frame_pool[frame_start], NULL);
    if (depth <= 0) return;
    buf->frame_pool_count += depth;

    /* Record normal sample (skip if first time — no prev_time) */
    if (!is_first) {
        int64_t weight = time_now - td->prev_time_ns;
        rperf_record_sample(prof, frame_start, depth, weight, RPERF_SAMPLE_NORMAL, td->thread_seq);
    }

    /* Save stack and timestamp for READY/RESUMED */
    td->suspended_at_ns = wall_now;
    td->suspended_frame_start = frame_start;
    td->suspended_frame_depth = depth;
    td->prev_time_ns = time_now;
    td->prev_wall_ns = wall_now;
}

static void
rperf_handle_ready(rperf_profiler_t *prof, VALUE thread)
{
    /* May NOT have GVL — only simple C operations allowed */
    rperf_thread_data_t *td = (rperf_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);
    if (!td) return;

    td->ready_at_ns = rperf_wall_time_ns();
}

static void
rperf_handle_resumed(rperf_profiler_t *prof, VALUE thread)
{
    /* Has GVL */
    rperf_thread_data_t *td = (rperf_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);

    if (td == NULL) {
        td = rperf_thread_data_create(prof, thread);
        if (!td) return;
    }

    int64_t wall_now = rperf_wall_time_ns();

    /* Record GVL blocked/wait samples (wall mode only) */
    if (prof->mode == 1 && td->suspended_frame_depth > 0) {
        if (td->ready_at_ns > 0 && td->ready_at_ns > td->suspended_at_ns) {
            int64_t blocked_ns = td->ready_at_ns - td->suspended_at_ns;
            rperf_record_sample(prof, td->suspended_frame_start,
                                td->suspended_frame_depth, blocked_ns,
                                RPERF_SAMPLE_GVL_BLOCKED, td->thread_seq);
        }
        if (td->ready_at_ns > 0 && wall_now > td->ready_at_ns) {
            int64_t wait_ns = wall_now - td->ready_at_ns;
            rperf_record_sample(prof, td->suspended_frame_start,
                                td->suspended_frame_depth, wait_ns,
                                RPERF_SAMPLE_GVL_WAIT, td->thread_seq);
        }
    }

    /* Reset prev times to current — next timer sample measures from resume */
    int64_t time_now = rperf_current_time_ns(prof, td);
    if (time_now >= 0) td->prev_time_ns = time_now;
    td->prev_wall_ns = wall_now;

    /* Clear suspended state */
    td->suspended_frame_depth = 0;
    td->ready_at_ns = 0;
}

static void
rperf_handle_exited(rperf_profiler_t *prof, VALUE thread)
{
    rperf_thread_data_t *td = (rperf_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);
    if (td) {
        free(td);
        rb_internal_thread_specific_set(thread, prof->ts_key, NULL);
    }
}

static void
rperf_thread_event_hook(rb_event_flag_t event, const rb_internal_thread_event_data_t *data, void *user_data)
{
    rperf_profiler_t *prof = (rperf_profiler_t *)user_data;
    if (!prof->running) return;

    VALUE thread = data->thread;

    if (event & RUBY_INTERNAL_THREAD_EVENT_SUSPENDED)
        rperf_handle_suspended(prof, thread);
    else if (event & RUBY_INTERNAL_THREAD_EVENT_READY)
        rperf_handle_ready(prof, thread);
    else if (event & RUBY_INTERNAL_THREAD_EVENT_RESUMED)
        rperf_handle_resumed(prof, thread);
    else if (event & RUBY_INTERNAL_THREAD_EVENT_EXITED)
        rperf_handle_exited(prof, thread);
}

/* ---- GC event hook ---- */

static void
rperf_gc_event_hook(rb_event_flag_t event, VALUE data, VALUE self, ID id, VALUE klass)
{
    rperf_profiler_t *prof = &g_profiler;
    if (!prof->running) return;

    if (event & RUBY_INTERNAL_EVENT_GC_START) {
        prof->gc.phase = RPERF_GC_MARKING;
    }
    else if (event & RUBY_INTERNAL_EVENT_GC_END_MARK) {
        prof->gc.phase = RPERF_GC_SWEEPING;
    }
    else if (event & RUBY_INTERNAL_EVENT_GC_END_SWEEP) {
        prof->gc.phase = RPERF_GC_NONE;
    }
    else if (event & RUBY_INTERNAL_EVENT_GC_ENTER) {
        /* Capture backtrace and timestamp at GC entry */
        prof->gc.enter_ns = rperf_wall_time_ns();

        rperf_sample_buffer_t *buf = &prof->buffers[atomic_load_explicit(&prof->active_idx, memory_order_relaxed)];
        if (rperf_ensure_frame_pool_capacity(buf, RPERF_MAX_STACK_DEPTH) < 0) return;
        size_t frame_start = buf->frame_pool_count;
        int depth = rb_profile_frames(0, RPERF_MAX_STACK_DEPTH,
                                      &buf->frame_pool[frame_start], NULL);
        if (depth <= 0) {
            prof->gc.frame_depth = 0;
            return;
        }
        buf->frame_pool_count += depth;
        prof->gc.frame_start = frame_start;
        prof->gc.frame_depth = depth;

        /* Save thread_seq for the GC_EXIT sample */
        {
            VALUE thread = rb_thread_current();
            rperf_thread_data_t *td = (rperf_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);
            prof->gc.thread_seq = td ? td->thread_seq : 0;
        }
    }
    else if (event & RUBY_INTERNAL_EVENT_GC_EXIT) {
        if (prof->gc.frame_depth <= 0) return;

        int64_t wall_now = rperf_wall_time_ns();
        int64_t weight = wall_now - prof->gc.enter_ns;
        int type = (prof->gc.phase == RPERF_GC_SWEEPING)
                   ? RPERF_SAMPLE_GC_SWEEPING
                   : RPERF_SAMPLE_GC_MARKING;

        rperf_record_sample(prof, prof->gc.frame_start,
                            prof->gc.frame_depth, weight, type, prof->gc.thread_seq);
        prof->gc.frame_depth = 0;
    }
}

/* ---- Sampling callback (postponed job) — current thread only ---- */

static void
rperf_sample_job(void *arg)
{
    rperf_profiler_t *prof = (rperf_profiler_t *)arg;

    if (!prof->running) return;

    /* Measure sampling overhead */
    struct timespec ts_start, ts_end;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts_start);

    VALUE thread = rb_thread_current();

    /* Get/create per-thread data */
    rperf_thread_data_t *td = (rperf_thread_data_t *)rb_internal_thread_specific_get(thread, prof->ts_key);
    if (td == NULL) {
        td = rperf_thread_data_create(prof, thread);
        if (!td) return;
        return; /* Skip first sample for this thread */
    }

    int64_t time_now = rperf_current_time_ns(prof, td);
    if (time_now < 0) return;

    int64_t weight = time_now - td->prev_time_ns;
    td->prev_time_ns = time_now;
    td->prev_wall_ns = rperf_wall_time_ns();

    if (weight <= 0) return;

    /* Capture backtrace and record sample */
    rperf_sample_buffer_t *buf = &prof->buffers[atomic_load_explicit(&prof->active_idx, memory_order_relaxed)];
    if (rperf_ensure_frame_pool_capacity(buf, RPERF_MAX_STACK_DEPTH) < 0) return;

    size_t frame_start = buf->frame_pool_count;
    int depth = rb_profile_frames(0, RPERF_MAX_STACK_DEPTH,
                                  &buf->frame_pool[frame_start], NULL);
    if (depth <= 0) return;
    buf->frame_pool_count += depth;

    rperf_record_sample(prof, frame_start, depth, weight, RPERF_SAMPLE_NORMAL, td->thread_seq);

    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts_end);
    prof->stats.sampling_count++;
    prof->stats.sampling_total_ns +=
        ((int64_t)ts_end.tv_sec - ts_start.tv_sec) * 1000000000LL +
        (ts_end.tv_nsec - ts_start.tv_nsec);
}

/* ---- Worker thread: timer + aggregation ---- */

#if RPERF_USE_TIMER_SIGNAL
static void
rperf_signal_handler(int sig)
{
    g_profiler.stats.trigger_count++;
    rb_postponed_job_trigger(g_profiler.pj_handle);
}

/* Worker thread for signal mode: aggregation only.
 * Timer signals are directed to this thread via SIGEV_THREAD_ID,
 * and handled by the sigaction handler (rperf_signal_handler).
 * This ensures the timer signal does not interrupt other threads. */
static void *
rperf_worker_signal_func(void *arg)
{
    rperf_profiler_t *prof = (rperf_profiler_t *)arg;

    /* Publish our kernel TID so start() can use it for SIGEV_THREAD_ID */
    CHECKED(pthread_mutex_lock(&prof->worker_mutex));
    prof->worker_tid = (pid_t)syscall(SYS_gettid);
    CHECKED(pthread_cond_signal(&prof->worker_cond));

    while (prof->running) {
        CHECKED(pthread_cond_wait(&prof->worker_cond, &prof->worker_mutex));
        rperf_try_aggregate(prof);
    }
    CHECKED(pthread_mutex_unlock(&prof->worker_mutex));
    return NULL;
}
#endif

/* Worker thread for nanosleep mode: timer + aggregation.
 * Uses pthread_cond_timedwait with absolute deadline.
 * Timeout → trigger + advance deadline.
 * Signal (swap_ready) → aggregate only, keep same deadline. */
static void *
rperf_worker_nanosleep_func(void *arg)
{
    rperf_profiler_t *prof = (rperf_profiler_t *)arg;
    struct timespec deadline;
    long interval_ns = 1000000000L / prof->frequency;

    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_nsec += interval_ns;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000L;
    }

    CHECKED(pthread_mutex_lock(&prof->worker_mutex));
    while (prof->running) {
        int ret = pthread_cond_timedwait(&prof->worker_cond, &prof->worker_mutex, &deadline);
        assert(ret == 0 || ret == ETIMEDOUT);
        if (ret == ETIMEDOUT) {
            prof->stats.trigger_count++;
            rb_postponed_job_trigger(prof->pj_handle);
            /* Advance deadline by interval */
            deadline.tv_nsec += interval_ns;
            if (deadline.tv_nsec >= 1000000000L) {
                deadline.tv_sec++;
                deadline.tv_nsec -= 1000000000L;
            }
        }
        rperf_try_aggregate(prof);
    }
    CHECKED(pthread_mutex_unlock(&prof->worker_mutex));
    return NULL;
}

/* ---- Resolve frame VALUE to [path, label] Ruby strings ---- */

static VALUE
rperf_resolve_frame(VALUE fval)
{
    VALUE path = rb_profile_frame_path(fval);
    VALUE label = rb_profile_frame_full_label(fval);

    if (NIL_P(path))  path  = rb_str_new_lit("<C method>");

    if (NIL_P(path))  path  = rb_str_new_cstr("");
    if (NIL_P(label)) label = rb_str_new_cstr("");

    return rb_ary_new3(2, path, label);
}

/* ---- Ruby API ---- */

/* _c_start(frequency, mode, aggregate, signal)
 *   frequency: Integer (Hz)
 *   mode:      0 = cpu, 1 = wall
 *   aggregate: 0 or 1
 *   signal:    Integer (RT signal number, 0 = nanosleep, -1 = default)
 */
static VALUE
rb_rperf_start(VALUE self, VALUE vfreq, VALUE vmode, VALUE vagg, VALUE vsig)
{
    int frequency = NUM2INT(vfreq);
    int mode = NUM2INT(vmode);
    int aggregate = RTEST(vagg) ? 1 : 0;
#if RPERF_USE_TIMER_SIGNAL
    int sig = NUM2INT(vsig);
    int timer_signal = (sig < 0) ? RPERF_TIMER_SIGNAL_DEFAULT : sig;
#endif

    if (g_profiler.running) {
        rb_raise(rb_eRuntimeError, "Rperf is already running");
    }

    g_profiler.frequency = frequency;
    g_profiler.mode = mode;
    g_profiler.aggregate = aggregate;
    g_profiler.next_thread_seq = 0;
    g_profiler.stats.sampling_count = 0;
    g_profiler.stats.sampling_total_ns = 0;
    g_profiler.stats.trigger_count = 0;
    atomic_store_explicit(&g_profiler.active_idx, 0, memory_order_relaxed);
    atomic_store_explicit(&g_profiler.swap_ready, 0, memory_order_relaxed);

    /* Initialize worker mutex/cond */
    CHECKED(pthread_mutex_init(&g_profiler.worker_mutex, NULL));
    CHECKED(pthread_cond_init(&g_profiler.worker_cond, NULL));

    /* Initialize sample buffer(s) */
    if (rperf_sample_buffer_init(&g_profiler.buffers[0]) < 0) {
        CHECKED(pthread_mutex_destroy(&g_profiler.worker_mutex));
        CHECKED(pthread_cond_destroy(&g_profiler.worker_cond));
        rb_raise(rb_eNoMemError, "rperf: failed to allocate sample buffer 0");
    }
    if (aggregate) {
        if (rperf_sample_buffer_init(&g_profiler.buffers[1]) < 0) {
            rperf_sample_buffer_free(&g_profiler.buffers[0]);
            CHECKED(pthread_mutex_destroy(&g_profiler.worker_mutex));
            CHECKED(pthread_cond_destroy(&g_profiler.worker_cond));
            rb_raise(rb_eNoMemError, "rperf: failed to allocate sample buffer 1");
        }

        /* Initialize aggregation structures */
        if (rperf_frame_table_init(&g_profiler.frame_table) < 0) {
            rperf_sample_buffer_free(&g_profiler.buffers[0]);
            rperf_sample_buffer_free(&g_profiler.buffers[1]);
            CHECKED(pthread_mutex_destroy(&g_profiler.worker_mutex));
            CHECKED(pthread_cond_destroy(&g_profiler.worker_cond));
            rb_raise(rb_eNoMemError, "rperf: failed to allocate frame table");
        }
        if (rperf_agg_table_init(&g_profiler.agg_table) < 0) {
            rperf_frame_table_free(&g_profiler.frame_table);
            rperf_sample_buffer_free(&g_profiler.buffers[0]);
            rperf_sample_buffer_free(&g_profiler.buffers[1]);
            CHECKED(pthread_mutex_destroy(&g_profiler.worker_mutex));
            CHECKED(pthread_cond_destroy(&g_profiler.worker_cond));
            rb_raise(rb_eNoMemError, "rperf: failed to allocate aggregation table");
        }
    }

    /* Register GC event hook */
    g_profiler.gc.phase = RPERF_GC_NONE;
    g_profiler.gc.frame_depth = 0;
    rb_add_event_hook(rperf_gc_event_hook,
                      RUBY_INTERNAL_EVENT_GC_START |
                      RUBY_INTERNAL_EVENT_GC_END_MARK |
                      RUBY_INTERNAL_EVENT_GC_END_SWEEP |
                      RUBY_INTERNAL_EVENT_GC_ENTER |
                      RUBY_INTERNAL_EVENT_GC_EXIT,
                      Qnil);

    /* Register thread event hook for all events */
    g_profiler.thread_hook = rb_internal_thread_add_event_hook(
        rperf_thread_event_hook,
        RUBY_INTERNAL_THREAD_EVENT_EXITED |
        RUBY_INTERNAL_THREAD_EVENT_SUSPENDED |
        RUBY_INTERNAL_THREAD_EVENT_READY |
        RUBY_INTERNAL_THREAD_EVENT_RESUMED,
        &g_profiler);

    /* Pre-initialize current thread's time so the first sample is not skipped */
    {
        VALUE cur_thread = rb_thread_current();
        rperf_thread_data_t *td = rperf_thread_data_create(&g_profiler, cur_thread);
        if (!td) {
            rb_remove_event_hook(rperf_gc_event_hook);
            rb_internal_thread_remove_event_hook(g_profiler.thread_hook);
            g_profiler.thread_hook = NULL;
            if (g_profiler.aggregate) {
                rperf_sample_buffer_free(&g_profiler.buffers[1]);
                rperf_frame_table_free(&g_profiler.frame_table);
                rperf_agg_table_free(&g_profiler.agg_table);
            }
            rperf_sample_buffer_free(&g_profiler.buffers[0]);
            CHECKED(pthread_mutex_destroy(&g_profiler.worker_mutex));
            CHECKED(pthread_cond_destroy(&g_profiler.worker_cond));
            rb_raise(rb_eNoMemError, "rperf: failed to allocate thread data");
        }
    }

    clock_gettime(CLOCK_REALTIME, &g_profiler.start_realtime);
    clock_gettime(CLOCK_MONOTONIC, &g_profiler.start_monotonic);

    g_profiler.running = 1;

#if RPERF_USE_TIMER_SIGNAL
    g_profiler.timer_signal = timer_signal;

    if (timer_signal > 0) {
        struct sigaction sa;
        struct sigevent sev;
        struct itimerspec its;

        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = rperf_signal_handler;
        sa.sa_flags = SA_RESTART;
        sigaction(g_profiler.timer_signal, &sa, &g_profiler.old_sigaction);

        /* Start worker thread first to get its kernel TID */
        g_profiler.worker_tid = 0;
        if (pthread_create(&g_profiler.worker_thread, NULL,
                           rperf_worker_signal_func, &g_profiler) != 0) {
            g_profiler.running = 0;
            sigaction(g_profiler.timer_signal, &g_profiler.old_sigaction, NULL);
            goto timer_fail;
        }

        /* Wait for worker thread to publish its TID */
        CHECKED(pthread_mutex_lock(&g_profiler.worker_mutex));
        while (g_profiler.worker_tid == 0) {
            CHECKED(pthread_cond_wait(&g_profiler.worker_cond, &g_profiler.worker_mutex));
        }
        CHECKED(pthread_mutex_unlock(&g_profiler.worker_mutex));

        /* Create timer targeting the worker thread via SIGEV_THREAD_ID */
        memset(&sev, 0, sizeof(sev));
        sev.sigev_notify = SIGEV_THREAD_ID;
        sev.sigev_signo = g_profiler.timer_signal;
        sev._sigev_un._tid = g_profiler.worker_tid;
        if (timer_create(CLOCK_MONOTONIC, &sev, &g_profiler.timer_id) != 0) {
            g_profiler.running = 0;
            sigaction(g_profiler.timer_signal, &g_profiler.old_sigaction, NULL);
            CHECKED(pthread_cond_signal(&g_profiler.worker_cond));
            CHECKED(pthread_join(g_profiler.worker_thread, NULL));
            goto timer_fail;
        }

        its.it_value.tv_sec = 0;
        its.it_value.tv_nsec = 1000000000L / g_profiler.frequency;
        its.it_interval = its.it_value;
        timer_settime(g_profiler.timer_id, 0, &its, NULL);
    } else
#endif
    {
        /* Start worker thread (timer via timedwait + aggregation) */
        if (pthread_create(&g_profiler.worker_thread, NULL,
                           rperf_worker_nanosleep_func, &g_profiler) != 0) {
            g_profiler.running = 0;
            goto timer_fail;
        }
    }

    if (0) {
timer_fail:
        {
            VALUE cur = rb_thread_current();
            rperf_thread_data_t *td = (rperf_thread_data_t *)rb_internal_thread_specific_get(cur, g_profiler.ts_key);
            if (td) {
                free(td);
                rb_internal_thread_specific_set(cur, g_profiler.ts_key, NULL);
            }
        }
        rb_remove_event_hook(rperf_gc_event_hook);
        rb_internal_thread_remove_event_hook(g_profiler.thread_hook);
        g_profiler.thread_hook = NULL;
        if (g_profiler.aggregate) {
            rperf_sample_buffer_free(&g_profiler.buffers[1]);
            rperf_frame_table_free(&g_profiler.frame_table);
            rperf_agg_table_free(&g_profiler.agg_table);
        }
        rperf_sample_buffer_free(&g_profiler.buffers[0]);
        CHECKED(pthread_mutex_destroy(&g_profiler.worker_mutex));
        CHECKED(pthread_cond_destroy(&g_profiler.worker_cond));
        rb_raise(rb_eRuntimeError, "rperf: failed to create timer");
    }

    return Qtrue;
}

static VALUE
rb_rperf_stop(VALUE self)
{
    VALUE result, samples_ary;
    size_t i;
    int j;

    if (!g_profiler.running) {
        return Qnil;
    }

    g_profiler.running = 0;
#if RPERF_USE_TIMER_SIGNAL
    if (g_profiler.timer_signal > 0) {
        timer_delete(g_profiler.timer_id);
        sigaction(g_profiler.timer_signal, &g_profiler.old_sigaction, NULL);
    }
#endif

    /* Wake and join worker thread */
    CHECKED(pthread_cond_signal(&g_profiler.worker_cond));
    CHECKED(pthread_join(g_profiler.worker_thread, NULL));
    CHECKED(pthread_mutex_destroy(&g_profiler.worker_mutex));
    CHECKED(pthread_cond_destroy(&g_profiler.worker_cond));

    if (g_profiler.thread_hook) {
        rb_internal_thread_remove_event_hook(g_profiler.thread_hook);
        g_profiler.thread_hook = NULL;
    }

    /* Remove GC event hook */
    rb_remove_event_hook(rperf_gc_event_hook);

    if (g_profiler.aggregate) {
        /* Worker thread is joined; no concurrent access to these atomics. */
        int cur_idx = atomic_load_explicit(&g_profiler.active_idx, memory_order_relaxed);
        /* Aggregate remaining samples from both buffers */
        if (atomic_load_explicit(&g_profiler.swap_ready, memory_order_relaxed)) {
            int standby_idx = cur_idx ^ 1;
            rperf_aggregate_buffer(&g_profiler, &g_profiler.buffers[standby_idx]);
            atomic_store_explicit(&g_profiler.swap_ready, 0, memory_order_relaxed);
        }
        rperf_aggregate_buffer(&g_profiler, &g_profiler.buffers[cur_idx]);
    }

    /* Clean up thread-specific data for all live threads */
    {
        VALUE threads = rb_funcall(rb_cThread, rb_intern("list"), 0);
        long tc = RARRAY_LEN(threads);
        long ti;
        for (ti = 0; ti < tc; ti++) {
            VALUE thread = RARRAY_AREF(threads, ti);
            rperf_thread_data_t *td = (rperf_thread_data_t *)rb_internal_thread_specific_get(thread, g_profiler.ts_key);
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

    /* trigger_count, sampling_count, sampling_time_ns */
    rb_hash_aset(result, ID2SYM(rb_intern("trigger_count")), SIZET2NUM(g_profiler.stats.trigger_count));
    rb_hash_aset(result, ID2SYM(rb_intern("sampling_count")), SIZET2NUM(g_profiler.stats.sampling_count));
    rb_hash_aset(result, ID2SYM(rb_intern("sampling_time_ns")), LONG2NUM(g_profiler.stats.sampling_total_ns));

    /* aggregation stats */
    if (g_profiler.aggregate) {
        rb_hash_aset(result, ID2SYM(rb_intern("unique_frames")),
                     SIZET2NUM(g_profiler.frame_table.count - RPERF_SYNTHETIC_COUNT));
        rb_hash_aset(result, ID2SYM(rb_intern("unique_stacks")),
                     SIZET2NUM(g_profiler.agg_table.count));
    }

    /* start_time_ns (CLOCK_REALTIME epoch nanos), duration_ns (CLOCK_MONOTONIC delta) */
    {
        struct timespec stop_monotonic;
        int64_t start_ns, duration_ns;
        clock_gettime(CLOCK_MONOTONIC, &stop_monotonic);
        start_ns = (int64_t)g_profiler.start_realtime.tv_sec * 1000000000LL
                 + (int64_t)g_profiler.start_realtime.tv_nsec;
        duration_ns = ((int64_t)stop_monotonic.tv_sec - (int64_t)g_profiler.start_monotonic.tv_sec) * 1000000000LL
                    + ((int64_t)stop_monotonic.tv_nsec - (int64_t)g_profiler.start_monotonic.tv_nsec);
        rb_hash_aset(result, ID2SYM(rb_intern("start_time_ns")), LONG2NUM(start_ns));
        rb_hash_aset(result, ID2SYM(rb_intern("duration_ns")), LONG2NUM(duration_ns));
    }

    if (g_profiler.aggregate) {
        /* Build samples from aggregation table.
         * Use a Ruby array for resolved frames so GC protects them. */
        rperf_frame_table_t *ft = &g_profiler.frame_table;
        VALUE resolved_ary = rb_ary_new_capa((long)ft->count);
        /* Synthetic frames */
        rb_ary_push(resolved_ary, rb_ary_new3(2, rb_str_new_lit("<GVL>"), rb_str_new_lit("[GVL blocked]")));
        rb_ary_push(resolved_ary, rb_ary_new3(2, rb_str_new_lit("<GVL>"), rb_str_new_lit("[GVL wait]")));
        rb_ary_push(resolved_ary, rb_ary_new3(2, rb_str_new_lit("<GC>"),  rb_str_new_lit("[GC marking]")));
        rb_ary_push(resolved_ary, rb_ary_new3(2, rb_str_new_lit("<GC>"),  rb_str_new_lit("[GC sweeping]")));
        /* Real frames */
        for (i = RPERF_SYNTHETIC_COUNT; i < ft->count; i++) {
            rb_ary_push(resolved_ary, rperf_resolve_frame(atomic_load_explicit(&ft->keys, memory_order_relaxed)[i]));
        }

        rperf_agg_table_t *at = &g_profiler.agg_table;
        samples_ary = rb_ary_new();
        for (i = 0; i < at->bucket_capacity; i++) {
            rperf_agg_entry_t *e = &at->buckets[i];
            if (!e->used) continue;

            VALUE frames = rb_ary_new_capa(e->depth);
            for (j = 0; j < e->depth; j++) {
                uint32_t fid = at->stack_pool[e->frame_start + j];
                rb_ary_push(frames, RARRAY_AREF(resolved_ary, fid));
            }

            VALUE sample = rb_ary_new3(3, frames, LONG2NUM(e->weight), INT2NUM(e->thread_seq));
            rb_ary_push(samples_ary, sample);
        }

        rperf_sample_buffer_free(&g_profiler.buffers[1]);
        rperf_frame_table_free(&g_profiler.frame_table);
        rperf_agg_table_free(&g_profiler.agg_table);
    } else {
        /* Raw samples path (aggregate: false) */
        rperf_sample_buffer_t *buf = &g_profiler.buffers[0];
        samples_ary = rb_ary_new_capa((long)buf->sample_count);
        for (i = 0; i < buf->sample_count; i++) {
            rperf_sample_t *s = &buf->samples[i];
            VALUE frames = rb_ary_new_capa(s->depth + 1);

            /* Prepend synthetic frame at leaf position (index 0) */
            if (s->type == RPERF_SAMPLE_GVL_BLOCKED) {
                VALUE syn = rb_ary_new3(2, rb_str_new_lit("<GVL>"), rb_str_new_lit("[GVL blocked]"));
                rb_ary_push(frames, syn);
            } else if (s->type == RPERF_SAMPLE_GVL_WAIT) {
                VALUE syn = rb_ary_new3(2, rb_str_new_lit("<GVL>"), rb_str_new_lit("[GVL wait]"));
                rb_ary_push(frames, syn);
            } else if (s->type == RPERF_SAMPLE_GC_MARKING) {
                VALUE syn = rb_ary_new3(2, rb_str_new_lit("<GC>"), rb_str_new_lit("[GC marking]"));
                rb_ary_push(frames, syn);
            } else if (s->type == RPERF_SAMPLE_GC_SWEEPING) {
                VALUE syn = rb_ary_new3(2, rb_str_new_lit("<GC>"), rb_str_new_lit("[GC sweeping]"));
                rb_ary_push(frames, syn);
            }

            for (j = 0; j < s->depth; j++) {
                VALUE fval = buf->frame_pool[s->frame_start + j];
                rb_ary_push(frames, rperf_resolve_frame(fval));
            }

            VALUE sample = rb_ary_new3(3, frames, LONG2NUM(s->weight), INT2NUM(s->thread_seq));
            rb_ary_push(samples_ary, sample);
        }
    }
    rb_hash_aset(result,
                 ID2SYM(rb_intern(g_profiler.aggregate ? "aggregated_samples" : "raw_samples")),
                 samples_ary);

    /* Cleanup */
    rperf_sample_buffer_free(&g_profiler.buffers[0]);

    return result;
}

/* ---- Fork safety ---- */

static void
rperf_after_fork_child(void)
{
    if (!g_profiler.running) return;

    /* Mark as not running — timer doesn't exist in child */
    g_profiler.running = 0;

#if RPERF_USE_TIMER_SIGNAL
    /* timer_create timers are not inherited across fork; restore old signal handler */
    if (g_profiler.timer_signal > 0) {
        sigaction(g_profiler.timer_signal, &g_profiler.old_sigaction, NULL);
    }
#endif

    /* Remove hooks so they don't fire with stale state */
    if (g_profiler.thread_hook) {
        rb_internal_thread_remove_event_hook(g_profiler.thread_hook);
        g_profiler.thread_hook = NULL;
    }
    rb_remove_event_hook(rperf_gc_event_hook);

    /* Free sample buffers, frame table, and agg table — these hold parent's data */
    rperf_sample_buffer_free(&g_profiler.buffers[0]);
    if (g_profiler.aggregate) {
        rperf_sample_buffer_free(&g_profiler.buffers[1]);
        rperf_frame_table_free(&g_profiler.frame_table);
        rperf_agg_table_free(&g_profiler.agg_table);
    }

    /* Reset GC state */
    g_profiler.gc.phase = 0;

    /* Reset stats */
    g_profiler.stats.sampling_count = 0;
    g_profiler.stats.sampling_total_ns = 0;
    atomic_store_explicit(&g_profiler.swap_ready, 0, memory_order_relaxed);
}

/* ---- Init ---- */

void
Init_rperf(void)
{
    VALUE mRperf = rb_define_module("Rperf");
    rb_define_module_function(mRperf, "_c_start", rb_rperf_start, 4);
    rb_define_module_function(mRperf, "_c_stop", rb_rperf_stop, 0);

    memset(&g_profiler, 0, sizeof(g_profiler));
    g_profiler.pj_handle = rb_postponed_job_preregister(0, rperf_sample_job, &g_profiler);
    g_profiler.ts_key = rb_internal_thread_specific_key_create();

    /* TypedData wrapper for GC marking of frame_pool */
    g_profiler_wrapper = TypedData_Wrap_Struct(rb_cObject, &rperf_profiler_type, &g_profiler);
    rb_gc_register_address(&g_profiler_wrapper);

    /* Fork safety: silently stop profiling in child process */
    CHECKED(pthread_atfork(NULL, NULL, rperf_after_fork_child));
}
