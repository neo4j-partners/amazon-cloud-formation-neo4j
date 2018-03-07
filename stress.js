/*
 * Quick stress testing script to apply lots of concurrent writes to the cluster.
 */
const neo4j = require('neo4j-driver').v1;
const Promise = require('bluebird');
const uuid = require('uuid');

const TOTAL_HITS = 80000;

const concurrency = { concurrency: process.env.CONCURRENCY || 50 };

if (!process.env.NEO4J_URI) {
  console.error('Set env vars NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD');
  process.exit(1);
}

console.log('Connecting to ', process.env.NEO4J_URI);

const driver = neo4j.driver(process.env.NEO4J_URI,
  neo4j.auth.basic(process.env.NEO4J_USER,
    process.env.NEO4J_PASSWORD) );

const session = driver.session();

let completed = 0;

const stats = {};

const checkpoint = data => {
   completed++;
   if(completed % (process.env.CHECKPOINT_FREQUENCY || 50) === 0) {
     console.log('Completed: ', completed, stats);
   }
   return data;
};

const randInt = max =>
  Math.floor(Math.random() * Math.floor(max));

const didStrategy = name => {
  stats[name] = (stats[name] || 0) + 1;
};

const runQuery = () => {
  const roll = Math.random();

  if (roll <= 0.02) {
    didStrategy('randomLinks');
    return session.run(`
      MATCH (n1:Node),(n2:Node) WITH n1, n2 LIMIT 100 WHERE rand() < 0.1
      CREATE (n1)-[:randomlink]->(n2)
    `).then(checkpoint);
  } else if(roll <= 0.04) {
    didStrategy('jumpover');
    const sp = randInt(10000);
    return session.run(`
      MATCH (a:Node)-[r1]-(b:Node)-[r2]-(c:Node)
      WHERE a.id >= $sp and a.id <= $sp + 1000 and b.id % 3 = 0 and c.id % 3 = 0
      WITH a, b, c LIMIT 800 WHERE rand() < 0.3
      CREATE (a)-[:jumpover { id: id(b) }]->(c)
      SET b:Jumpover
    `, { 
      sp,
    }).then(checkpoint);
  } else if(roll <= 0.09) {
    // Write a pile of properties.
    const p = randInt(10000000);
    const r = p - 10000;
    didStrategy('writeArray');

    const data = [];
    for (let i=0; i<100; i++) {
      data.push(uuid.v4());
    }

    return session.run(`
      MATCH (a:Node) WHERE a.id >= $r and a.id <= $p
      WITH a LIMIT 200
      SET a.list${randInt(100)} = $data SET a:WriteArray
      RETURN count(a);
    `, { data, r, p }).then(checkpoint);
  } else if (roll <= 0.13) {
    const ids = {};
    let query = '';

    didStrategy('append100');
    for (let i=0; i<100; i++) {
      ids[`id${i}`] = uuid.v4();
      query = query + `
        MERGE (i${i}:Node { id: $id${i} })
        ON CREATE SET i${i}:RandomAppend
      `;
    }

    query = query + ' RETURN null';
    return session.run(query, ids).then(checkpoint);
  } else {
    didStrategy('simpleWrites');
    return session.run(`
      MERGE (n:Node { id: $id1 }) ON CREATE SET n.uuid = $u1 SET n:SimpleWrite
      MERGE (p:Node { id: $id2 }) ON CREATE SET p.uuid = $u2 SET p:SimpleWrite
      MERGE (z:Node { id: $id3 }) ON CREATE SET z.uuid = $u3 SET z:SimpleWrite
      MERGE (n)-[:link {r: $r, uuid: $u4 }]->(p)
      MERGE (n)-[:otherlink { r: $r2, uuid: $u5 }]->(z)

      RETURN 1;`, { 
        r: randInt(100000), 
        id1: randInt(10000000), id2: randInt(10000000), id3: randInt(10000000),
        u1: uuid.v4(), u2: uuid.v4(), u3: uuid.v4(), u4: uuid.v4(), u5: uuid.v4(),
        r2: randInt(100000),
      })
      .then(checkpoint);
    }
};

// Pre-run this prior to script: FOREACH (id IN range(0,1000) | MERGE (:Node {id:id}));
const arr = Array.apply(null, { length: TOTAL_HITS }).map(Number.call, Number);

return session.run('CREATE INDEX ON :Node(id)')
  .then(() => console.log('Index created, writing seed nodes...'))
  .then(() => session.run('FOREACH (id IN range(0,1000) | MERGE (:Node {id:id}));'))
  .then(() => console.log('Starting parallel writes.'))
  .then(() => Promise.map(arr, item => runQuery(), concurrency))
  .then(results => console.log('All done!'))
  .catch(err => console.error(err))
  .finally(() => driver.close());

