# Stress Testing

I cooked up my own script for beating up clusters just to test that they're working roughly OK.

# Running Stand-Alone

```
npm install
export NEO4J_USER=neo4j
export NEO4J_PASSWORD=supersecret
export NEO4J_URI=bolt+routing://my-cloud-host:7687
node stress.js
```

Alternatively, you can pass some arguments, like this:

```
export NEO4J_USER=neo4j
export NEO4J_PASSWORD=supersecret
export NEO4J_URI=bolt+routing://my-cloud-host:7687

node stress.js --concurrency 10 --n 20 --workload /path/to/read-workload.json
```

This would run the read workload in batches of 20, with 10 concurrent queries.

See the `workloads` directory for the format of the probability table.

# Building Stress Testing as a Docker Container

```
docker build -t neo4j/stress:latest -f Dockerfile . 
```

# Running

```
docker run \
	-e "NEO4J_URI=bolt://foo-host/" \
	-e "NEO4J_USER=neo4j" \
	-e "NEO4J_PASSWORD=secret" \
	-e "CONCURRENCY=10" \
	neo4j/stress:latest 
```

# Running in Kubernetes

Tweak stress-testing.yaml, then

```
kubectl apply -f stress-testing.yaml --namespace default
```

# Adjusting Workload

This is not that friendly or configurable from the outside yet.  But essentially:

- Stress tester has a number of 'read strategies' and 'write strategies'
- There is a probability table; the stress tester rolls random numbers and picks a strategy
based on the probability table.
- By tweaking which strategies are available and what their probability is,  you can generate
whichever kind of load you like
- You can write a new strategy to simulate any specific kind of load you like.

See stress.js for details.