/*
 * Quick stress testing script to apply lots of concurrent writes to the cluster.
 */
const neo4j = require('neo4j-driver').v1;
const Promise = require('bluebird');
const uuid = require('uuid');

const TOTAL_HITS = 80000;

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

const NAryTreeStrategy = require('./NAryTreeStrategy');
const FatNodeAppendStrategy = require('./FatNodeAppendStrategy');
const MergeWriteStrategy = require('./MergeWriteStrategy');

const strategies = {
  nary: new NAryTreeStrategy({ n: 2 }),
  fatnode: new FatNodeAppendStrategy({}),
  mergewrite: new MergeWriteStrategy({ n: 1000000 }),
};

const probabilityTable = [
  [ 0.2, 'fatnode' ],
  [ 0.4, 'mergewrite' ],
  [ 1, 'nary' ],
];

const runStrategy = (driver) => {
  const roll = Math.random();

  let strat;
  let key;

  for (let i=0; i<probabilityTable.length; i++) {
    const entry = probabilityTable[i];
    if (roll <= entry[0]) {
      key = entry[1];
      break;
    }
  }

  strat = strategies[key];
  didStrategy(key);
  return strat.run(driver);
};

const setupPromises = Object.keys(strategies).map(key => strategies[key].setup(driver));

// Pre-run this prior to script: FOREACH (id IN range(0,1000) | MERGE (:Node {id:id}));
const arr = Array.apply(null, { length: TOTAL_HITS }).map(Number.call, Number);

console.log('Running setup actions for ', Object.keys(strategies).length, ' strategies; ', probabilityTable);
Promise.all(setupPromises)
  .then(() => console.log('Starting parallel strategies'))
  .then(() => Promise.map(arr, item => runStrategy(driver).then(checkpoint), concurrency))
  .catch(err => {
    console.error(err);
    Object.keys(strategies).forEach(strat => {
      console.log(strat, 'last query');
      console.log(strategies[strat].lastQuery);
      console.log(strategies[strat].lastParams);
    });
  })
  .finally(() => driver.close());
