# Benchmarks

A benchmark is just a directory with a shell scripts that provides the ability to
run a benchmark against a Neo4j endpoint.

All benchmark directories must provide a `benchmark.sh` file, that takes host and password
in that order.

## Inputs

Benchmarks may only require a host/IP and a password.

Example:  `benchmark.sh foohost.com superSecret`

## Outputs

Any number of key/value pairs of this form:

```
BENCHMARK_X=foo
BENCHMARK_Y=bar
BENCHMARK_ELAPSED=1231
```

At a minimum, `BENCHMARK_ELAPSED` should be output.