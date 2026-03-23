#include <ruby.h>
#include <ruby/thread.h>
#include <time.h>
#include <stdint.h>
#include <stdio.h>

static int64_t current_cpu_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static VALUE rperf_busy_wait_method(VALUE self, VALUE n_usec)
{
    int64_t target = current_cpu_ns() + NUM2LONG(n_usec) * 1000;
    while (current_cpu_ns() < target) {}
    return Qnil;
}

/* nanosleep with EINTR retry (e.g. profiler timer signals) */
static void
rperf_nanosleep_retry(const struct timespec *ts)
{
    struct timespec rem = *ts;
    while (nanosleep(&rem, &rem) == -1 && errno == EINTR) {
        /* continue with remaining time */
    }
}

static VALUE rperf_nanosleep_method(VALUE self, VALUE n_usec)
{
    struct timespec ts;
    long usec = NUM2LONG(n_usec);
    ts.tv_sec = usec / 1000000;
    ts.tv_nsec = (usec % 1000000) * 1000;
    rperf_nanosleep_retry(&ts);
    return Qnil;
}

/* nanosleep without GVL — simulates blocking I/O */
static void *
rperf_nanosleep_nogvl(void *arg)
{
    struct timespec *ts = (struct timespec *)arg;
    rperf_nanosleep_retry(ts);
    return NULL;
}

static VALUE rperf_cwait_method(VALUE self, VALUE n_usec)
{
    struct timespec ts;
    long usec = NUM2LONG(n_usec);
    ts.tv_sec = usec / 1000000;
    ts.tv_nsec = (usec % 1000000) * 1000;
    rb_thread_call_without_gvl(rperf_nanosleep_nogvl, &ts, RUBY_UBF_IO, NULL);
    return Qnil;
}

void Init_rperf_workload(void)
{
    VALUE mWorkload = rb_define_module("RperfWorkload");
    char name[16];
    int i;

    for (i = 1; i <= 1000; i++) {
        snprintf(name, sizeof(name), "cw%d", i);
        rb_define_module_function(mWorkload, name, rperf_busy_wait_method, 1);
    }

    for (i = 1; i <= 1000; i++) {
        snprintf(name, sizeof(name), "csleep%d", i);
        rb_define_module_function(mWorkload, name, rperf_nanosleep_method, 1);
    }

    for (i = 1; i <= 1000; i++) {
        snprintf(name, sizeof(name), "cwait%d", i);
        rb_define_module_function(mWorkload, name, rperf_cwait_method, 1);
    }
}
