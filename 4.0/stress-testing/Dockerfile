FROM node:9-alpine
MAINTAINER David Allen <david.allen@neo4j.com>
COPY src /src
RUN cd src && npm install
ENV NEO4J_URI "bolt://localhost"
ENV NEO4J_USER "neo4j"
ENV NEO4J_PASSWORD "neo4j"
ENV CONCURRENCY "10"

WORKDIR /src
CMD ["node", "stress.js"]
