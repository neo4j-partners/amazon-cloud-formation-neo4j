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

const TOTAL_HITS = 100000;
const p = Number(process.env.CONCURRENCY);
const concurrency = { concurrency: (!Number.isNaN(p) && p > 0) ? p : 10 };

// Each time, a random number is chosen, and this table is scanned through.
// If the random number is less than the strategy number, it executes.
// So for example if the random number is 0.30, then aggregateRead is executed.
// By tweaking the distribution of these numbers you can control how frequently
// each strategy is executed.
const probabilityTable = [
  [ 0.001, 'fatnodeWrite' ],
  [ 0.002, 'naryWrite' ],
  [ 0.25, 'mergeWrite' ],
  [ 0.50, 'aggregateRead' ],
  [ 0.55, 'metadataRead' ],
  [ 0.60, 'longPathRead' ],
  [ 1, 'rawWrite' ],
];

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
   if (interrupted) { return data; }

   stats.completed++;
   if(stats.completed % (process.env.CHECKPOINT_FREQUENCY || 50) === 0) {
     console.log(stats);
   }
   return data;
};

let interrupted = false;
const sigintHandler = () => {
  interrupted = true;
  console.log('Caught interrupt. Allowing current batch to finish.');
};

const didStrategy = name => {
  stats[name] = (stats[name] || 0) + 1;
};

const NAryTreeStrategy = require('./write-strategy/NAryTreeStrategy');
const FatNodeAppendStrategy = require('./write-strategy/FatNodeAppendStrategy');
const MergeWriteStrategy = require('./write-strategy/MergeWriteStrategy');
const RawWriteStrategy = require('./write-strategy/RawWriteStrategy');
const AggregateReadStrategy = require('./read-strategy/AggregateReadStrategy');
const MetadataReadStrategy = require('./read-strategy/MetadataReadStrategy');
const LongPathReadStrategy = require('./read-strategy/LongPathReadStrategy');

const strategies = {
  // WRITE STRATEGIES
  naryWrite: new NAryTreeStrategy({ n: 2 }),
  fatnodeWrite: new FatNodeAppendStrategy({}),
  mergeWrite: new MergeWriteStrategy({ n: 1000000 }),
  rawWrite: new RawWriteStrategy({ n: 10 }),

  // READ STRATEGIES
  aggregateRead: new AggregateReadStrategy({}),
  metadataRead: new MetadataReadStrategy({}),
  longPathRead: new LongPathReadStrategy({}),
};

const runStrategy = (driver) => {
  if (interrupted) { return Promise.resolve(null); }
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
process.on('SIGINT', sigintHandler);

Promise.all(setupPromises)
  .then(() => console.log(`Starting parallel strategies: concurrency ${concurrency.concurrency}`))
  .then(() => Promise.map(arr, item => runStrategy(driver).then(checkpoint), concurrency))
  .catch(err => {
    console.error(err);
    Object.keys(strategies).forEach(strat => {
      console.log(strat, 'last query');
      console.log(strategies[strat].lastQuery);
      console.log(strategies[strat].lastParams);
    });
  })
  .finally(() => driver.close())
  .then(() => {
    console.log('Strategy report');
    Object.keys(strategies).forEach(strategy => {
      const strat = strategies[strategy];
      strat.summarize();
    });
  })
