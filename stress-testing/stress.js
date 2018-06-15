/*
 * Quick stress testing script to apply lots of concurrent writes to the cluster.
 * 
 * Usage:
 * export NEO4J_URI=bolt+routing://localhost
 * export NEO4J_USERNAME=neo4j
 * export NEO4J_PASSWORD=super-secret
 * 
 * npm install
 * 
 * node stress.js
 * 
 * To customize the workload, consult the probabilityTable.
 */
const neo4j = require('neo4j-driver').v1;
const Promise = require('bluebird');
const uuid = require('uuid');

const TOTAL_HITS = 80000;

const writeProbabilityTable = [
  [ 0.001, 'fatnode' ],
  [ 0.002, 'nary' ],
  [ 0.25, 'mergewrite' ],
  [ 1, 'rawrite' ],
];

const concurrency = { concurrency: process.env.CONCURRENCY || 10 };

if (!process.env.NEO4J_URI) {
  console.error('Set env vars NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD');
  process.exit(1);
}

console.log('Connecting to ', process.env.NEO4J_URI);

const driver = neo4j.driver(process.env.NEO4J_URI,
  neo4j.auth.basic(process.env.NEO4J_USER,
    process.env.NEO4J_PASSWORD) );

const session = driver.session();

const stats = { completed: 0 };

const checkpoint = data => {
   stats.completed++;
   if(stats.completed % (process.env.CHECKPOINT_FREQUENCY || 50) === 0) {
     console.log(stats);
   }
   return data;
};

const didStrategy = name => {
  stats[name] = (stats[name] || 0) + 1;
};

const NAryTreeStrategy = require('./write-strategy/NAryTreeStrategy');
const FatNodeAppendStrategy = require('./write-strategy/FatNodeAppendStrategy');
const MergeWriteStrategy = require('./write-strategy/MergeWriteStrategy');
const RawWriteStrategy = require('./write-strategy/RawWriteStrategy');

const writeStrategies = {
  nary: new NAryTreeStrategy({ n: 2 }),
  fatnode: new FatNodeAppendStrategy({}),
  mergewrite: new MergeWriteStrategy({ n: 1000000 }),
  rawrite: new RawWriteStrategy({ n: 10 }),
};

const runStrategy = (driver) => {
  const roll = Math.random();

  let strat;
  let key;

  for (let i=0; i<writeProbabilityTable.length; i++) {
    const entry = writeProbabilityTable[i];
    if (roll <= entry[0]) {
      key = entry[1];
      break;
    }
  }

  strat = writeStrategies[key];
  didStrategy(key);
  return strat.run(driver);
};

const setupPromises = Object.keys(writeStrategies).map(key => writeStrategies[key].setup(driver));

// Pre-run this prior to script: FOREACH (id IN range(0,1000) | MERGE (:Node {id:id}));
const arr = Array.apply(null, { length: TOTAL_HITS }).map(Number.call, Number);

console.log('Running setup actions for ', Object.keys(writeStrategies).length, ' strategies; ', writeProbabilityTable);
Promise.all(setupPromises)
  .then(() => console.log('Starting parallel strategies'))
  .then(() => Promise.map(arr, item => runStrategy(driver).then(checkpoint), concurrency))
  .catch(err => {
    console.error(err);
    Object.keys(writeStrategies).forEach(strat => {
      console.log(strat, 'last query');
      console.log(writeStrategies[strat].lastQuery);
      console.log(writeStrategies[strat].lastParams);
    });
  })
  .finally(() => driver.close());
