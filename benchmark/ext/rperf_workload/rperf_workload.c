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

/* nanosleep with EINTR retry. Returns number of retries. */
static long
rperf_nanosleep_retry(const struct timespec *ts)
{
    struct timespec rem = *ts;
    long retries = 0;
    while (nanosleep(&rem, &rem) == -1 && errno == EINTR) {
        retries++;
    }
    return retries;
}

static VALUE rperf_nanosleep_method(VALUE self, VALUE n_usec)
{
    struct timespec ts;
    long usec = NUM2LONG(n_usec);
    ts.tv_sec = usec / 1000000;
    ts.tv_nsec = (usec % 1000000) * 1000;
    long retries = rperf_nanosleep_retry(&ts);
    return LONG2NUM(retries);
}

/* nanosleep without GVL — simulates blocking I/O */
typedef struct {
    struct timespec ts;
    long retries;
} rperf_nogvl_arg_t;

static void *
rperf_nanosleep_nogvl(void *arg)
{
    rperf_nogvl_arg_t *a = (rperf_nogvl_arg_t *)arg;
    a->retries = rperf_nanosleep_retry(&a->ts);
    return NULL;
}

static VALUE rperf_cwait_method(VALUE self, VALUE n_usec)
{
    rperf_nogvl_arg_t arg;
    long usec = NUM2LONG(n_usec);
    arg.ts.tv_sec = usec / 1000000;
    arg.ts.tv_nsec = (usec % 1000000) * 1000;
    arg.retries = 0;
    rb_thread_call_without_gvl(rperf_nanosleep_nogvl, &arg, RUBY_UBF_IO, NULL);
    return LONG2NUM(arg.retries);
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
