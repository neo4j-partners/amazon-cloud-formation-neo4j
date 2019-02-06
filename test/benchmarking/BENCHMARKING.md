# Benchmarking

This subdirectory is for testing performance of Neo4j clusters, and 
to gather data that lets us make relative judgments about neo4j clusters.

- Is google faster than AWS?
- How much effect does adding SSDs provide?
- How much does write speed degrade if we have 5 core nodes instead of 3
(larger consensus required)

# Usage

```
perl run-benchmark.pl <provider> <benchmark>
```

This will create a new Neo4j stack using <provider> and run <benchmark> on that stack.

Both arguments are **directory names**.  Example:

```
perl run-benchmarkpl providers/aws benchmarks/meetups
```

Consult the readmes in the subdirectories for more information on the benchmark and provider APIs.

As of this writing, there's only one benchmark but there are multiple providers.

# Getting a Dataset

```
for i in $(seq 1 100) ; 
   do echo "Running time...... $i" && ./run-benchmark.pl providers/localdocker/ benchmarks/stress-test/ ; 
done
```

This will produce a large number of `runlog-*.log` files, one for each run.

To parse them out to CSV:

```
npm install
node extract-results.js runlog-*.log
```

Happy hacking.