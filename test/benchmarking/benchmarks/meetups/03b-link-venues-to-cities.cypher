CALL apoc.periodic.iterate("MATCH (c:City) RETURN c.location as loc, c",
"WITH loc, c, 24140.2 as FifteenMilesInMeters
 MATCH (v:Venue)
 WHERE distance(v.location, c.location) < FifteenMilesInMeters
 MERGE (v)-[r:NEAR]->(c)", { batchSize: 500 })
YIELD batches, total
RETURN batches, total;
