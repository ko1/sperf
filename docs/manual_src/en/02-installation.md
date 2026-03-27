# Installation

## Installing the gem

rperf is distributed as a Ruby gem with a C extension:

```bash
gem install rperf
```

Or add it to your Gemfile:

```ruby
gem "rperf"
```

Then run:

```bash
bundle install
```

## Verifying the installation

Check that rperf is installed correctly:

```bash
rperf --help
```

You should see:

```
Usage: rperf record [options] command [args...]
       rperf stat [options] command [args...]
       rperf report [options] [file]
       rperf diff [options] base.pb.gz target.pb.gz
       rperf help

Run 'rperf help' for full documentation
```

## Platform support

rperf supports POSIX systems:

| Platform | Timer implementation | Notes |
|----------|---------------------|-------|
| Linux | `timer_create` + signal (default) | Best precision (~1000us at 1000Hz) |
| Linux | `nanosleep` thread (with `signal: false`) | Fallback, ~100us drift/tick |
| macOS | `nanosleep` thread | Signal-based timer not available |

On Linux, rperf uses `timer_create` with `SIGEV_SIGNAL` and a `sigaction` handler by default. This provides precise interval timing with no extra thread. The signal number defaults to `SIGRTMIN+8` and can be changed via the `signal:` keyword argument to `Rperf.start` in the Ruby API.

On macOS (and when `signal: false` is set on Linux), rperf falls back to a dedicated pthread with a `nanosleep` loop.

## Optional: Go toolchain

The `rperf report` and `rperf diff` subcommands are thin wrappers around `go tool pprof`. If you want to use these commands, install Go from [go.dev](https://go.dev/dl/).

Without Go, you can still use all other rperf features. You can view pprof files with other tools like [speedscope](https://www.speedscope.app/) or generate text/collapsed output directly.
