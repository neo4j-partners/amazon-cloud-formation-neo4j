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
const yargs = require('yargs');
const pool = require('./sessionPool');
const strategies = require('./strategies');

const args = yargs.argv;

const TOTAL_HITS = args.n || 100000;
const checkpointFrequency = args.checkpoint || process.env.CHECKPOINT_FREQUENCY || 200;

// Allow user to set concurrency through either the flag --concurrency or by env var.
const p = Number(args.concurrency) || Number(process.env.CONCURRENCY);
const concurrency = { concurrency: (!Number.isNaN(p) && p > 0) ? p : 10 };

// Each time, a random number is chosen, and this table is scanned through.
// If the random number is less than the strategy number, it executes.
// So for example if the random number is 0.30, then aggregateRead is executed.
// By tweaking the distribution of these numbers you can control how frequently
// each strategy is executed.
let probabilityTable = [
  [0.1, 'fatnodeWrite'],
  [0.2, 'naryWrite'],
  [0.3, 'mergeWrite'],
  [0.4, 'randomLinkage'],
  [0.45, 'starWrite'],
  [0.55, 'indexHeavy'],
  [0.60, 'aggregateRead'],
  [0.695, 'randomAccess'],
  // [ 0.60, 'metadataRead' ],
  [0.70, 'longPathRead'],
  [1, 'rawWrite'],
];

// probabilityTable = [
//   [ 1, 'lockTorture' ],
// ];

if (args.workload) {
  console.log('Loading workload ', args.workload);
  probabilityTable = require(args.workload);
}

if (!process.env.NEO4J_URI) {
  console.error('Set env vars NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD');
  process.exit(1);
}

if (!process.env.NEO4J_URI || !process.env.NEO4J_USER || !process.env.NEO4J_PASSWORD) {
  throw new Error('One or more of necessary NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD env vars missing');
}

console.log('Connecting to ', process.env.NEO4J_URI);

const driver = neo4j.driver(process.env.NEO4J_URI,
  neo4j.auth.basic(process.env.NEO4J_USER,
    process.env.NEO4J_PASSWORD));

const sessionPool = pool.getPool(driver, concurrency.concurrency + 5);

const stats = { completed: 0, running: 0 };

const checkpoint = data => {
  if (interrupted) { return data; }

  stats.completed++;
  stats.running = stats.running - 1;

  if (stats.completed % checkpointFrequency === 0) {
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

const runStrategy = (driver) => {
  if (interrupted) { return Promise.resolve(null); }
  const roll = Math.random();

  let strat;
  let key;

  for (let i = 0; i < probabilityTable.length; i++) {
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

// JS iterable lets us do Promise.map n times.
// https://javascript.info/iterable
let range = { from: 0, to: TOTAL_HITS };
range[Symbol.iterator] = function () { // function and not () => for "this" binding.
  return {
    current: this.from,
    last: this.to,

    next() {
      if (this.current <= this.last) {
        return { done: false, value: this.current++ };
      } else {
        return { done: true };
      }
    }
  };
};

console.log('Running setup actions for ', Object.keys(strategies).length, ' strategies; ');
console.log(JSON.stringify(probabilityTable, null, 2));
process.on('SIGINT', sigintHandler);

let exitCode = 0;

const startTime = new Date().getTime();

Promise.all(setupPromises)
  .then(() => console.log(`Starting parallel strategies: concurrency ${concurrency.concurrency}`))
  .then(() => Promise.map(range, () => {
    stats.running++;
    return runStrategy(driver).then(checkpoint);
  }, concurrency))
  .catch(err => {
    console.error(err);
    Object.keys(strategies).forEach(strat => {
      if (strategies[strat].lastQuery) {
        console.log(strat, 'last query');
        console.log(strategies[strat].lastQuery);
        console.log(strategies[strat].lastParams);
      }
    });
    exitCode = 1;
  })
  .finally(() => {
    console.log('Draining pool and closing connections');
    return sessionPool.drain()
      .then(() => sessionPool.clear())
      .catch(err => {
        console.error('Some error draining/clearing pool', err);
      })
      .then(() => driver.close());
  })
  .then(() => {
    const endTime = new Date().getTime();
    console.log('Strategy report');

    // Because strategies run in parallel, you can not time this
    // by adding their times.  Rather we time the overall execution
    // process.
    let totalElapsed = (endTime - startTime);

    Object.keys(strategies).forEach(strategy => {
      const strat = strategies[strategy];

      if (strat.countRuns() > 0) {
        strat.summarize();
      }
    });

    console.log(`BENCHMARK_ELAPSED=${totalElapsed}\n`);

    process.exit(exitCode);
  });
