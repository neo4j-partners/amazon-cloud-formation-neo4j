# Running Stand-Alone

```
cd src
npm install
node stress.js
```

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
