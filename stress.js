/*
 * Quick stress testing script to apply lots of concurrent writes to the cluster.
 */
const neo4j = require('neo4j-driver').v1;
const Promise = require('bluebird');

const concurrency = { concurrency: 100 };
const ips = [
  '35.196.168.249',
  '35.196.95.129',
  '35.196.54.155',
];

const url = 'bolt+routing://' + ips[0] + ':7687';
console.log('Connecting to ', url);

const driver = neo4j.driver(url,
  neo4j.auth.basic(process.env.NEO4J_USER,
    process.env.NEO4J_PASSWORD) );

const session = driver.session();

let completed = 0;

const checkpoint = data => {
   completed++;
   if(completed % 50 === 0) {
     console.log('Completed: ', completed);
   }
   return data;
};

const runQuery = () => {
  const id = Math.floor(Math.random() * 2000 % 1000);
  const blizz = Math.floor(Math.random() * 1000 % 1000) + 1000;
  const r = Math.floor(Math.random() * 5 % 5);
  return session.run('MERGE (n:Node { id: $id }) MERGE (p:Node { id: $blizz }) MERGE (n)-[:link {r: $r}]->(p) RETURN $blizz;', { r, id, blizz })
     .then(checkpoint);
};

// Pre-run this prior to script: FOREACH (id IN range(0,1000) | CREATE (:Node {id:id}));
let numbers = 8000;
const arr = Array.apply(null, { length: numbers }).map(Number.call, Number);

return Promise.map(arr, item => runQuery(), concurrency)
  .then(results => console.log('All done!'))
  .catch(err => console.error(err))
  .finally(() => driver.close());

