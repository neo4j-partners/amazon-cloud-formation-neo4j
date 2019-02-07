# Benchmarking

This subdirectory is for testing performance of Neo4j clusters, and 
to gather data that lets us make relative judgments about neo4j clusters.

- Is google faster than AWS?
- How much effect does adding SSDs provide?
- How much does write speed degrade if we have 5 core nodes instead of 3
(larger consensus required)

# How do these benchmarks work?

Briefly, you have providers (which know how to make neo4j instances) and 
benchmarks (which know how to run queries and measure stuff on an instance).

A benchmark run is when you apply a single benchmark to a provider.

* [Read more about providers](providers/PROVIDERS-API-README.md)
* [Read more about benchmarks](benchmarks/BENCHMARK-API-README.md)

# Usage

```
perl run-benchmark.pl <provider> <benchmark>
```

This will create a new Neo4j stack using <provider> and run <benchmark> on that stack.

Both arguments are **directory names**.  Example:

```
perl run-benchmarkpl providers/aws benchmarks/meetups
```

## Which providers are available?

`ls providers/`

## Which benchmarks are available?

`ls benchmarks/`

# Getting a Dataset

```
for i in $(seq 1 100) ; 
   do echo "Running time...... $i" && ./run-benchmark.pl providers/localdocker/ benchmarks/stress-test/ ; 
done
```

This will produce a large number of `runlog-*.log` files, one for each run.  I keep logs because they give me a complete dump.
There's a lot of things that can go wrong from provisioning, deprovisioning, and the benchmark failing.  So the benchmarks don't
output data directly, they just spit out logs.  We then process a lot of logs into an actual benchmark dataset.

This retains the flexibility to investigate a particular benchmark's run, while making it easy to rip out summary data about
100 runs.

To parse them out to CSV:

```
npm install
node extract-results.js runlog-*.log
```

Happy hacking.