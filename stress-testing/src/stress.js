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
const runConfiguration = require('./run-configuration');
const PromisePool = require('es6-promise-pool');
const _ = require('lodash');

const runConfig = runConfiguration(yargs.argv);

console.log('Connecting to ', runConfig.address);
const driver = neo4j.driver(runConfig.address,
  neo4j.auth.basic(runConfig.username, runConfig.password));

const sessionPool = pool.getPool(driver, runConfig.concurrency);

const shutdownConnections = () => {
  return sessionPool.drain()
    .then(() => sessionPool.clear())
    .catch(err => {
      console.error('Some error draining/clearing pool', err);
    })
    .then(() => driver.close());
};

const strategyTable = strategies.builder(sessionPool);
const stats = { completed: 0, running: 0, error: 0 };

const printStatus = () => {
  const pctDone = parseFloat(Math.round(runConfig.iterateUntil.progress() * 100)).toFixed(2);
  console.log(`Progress: ${pctDone}% ${stats.completed} completed; ${stats.running} running ${stats.error} error`);

  if (!interrupted) {
    // Schedule myself again.
    setTimeout(printStatus, runConfig.checkpointFreq);
  }
};

const checkpoint = data => {
  if (interrupted) { return data; }
  stats.completed++;
  stats.running = stats.running - 1;
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

  for (let i = 0; i < runConfig.probabilityTable.length; i++) {
    const entry = runConfig.probabilityTable[i];
    if (roll <= entry[0]) {
      key = entry[1];
      break;
    }
  }

  strat = strategyTable[key];
  didStrategy(key);
  return strat.run(driver);
};

console.log(_.pick(runConfig, [
  'address', 'username', 'concurrency', 'n', 'ms', 'checkpointFreq',
]));
process.on('SIGINT', sigintHandler);

let exitCode = 0;

const promiseProducer = () => {
  if (interrupted) { return null; }

  const v = runConfig.iterateUntil.next();
  if (v.done) {
    // Signal to the pool that we're done.
    return null;
  }

  stats.running++;
  return runStrategy(driver).then(checkpoint);
};

const promisePool = new PromisePool(promiseProducer, runConfig.concurrency);
promisePool.addEventListener('rejected', event => { stats.error++; });

const phase = (phase, fn) => {
  console.log('Beginning phase', phase);
  return fn();
};

const setupPromisesFn = () =>
  Object.keys(strategyTable).map(key => strategyTable[key].setup(driver));

const main = () => {
  const startTime = new Date().getTime();

  return Promise.all(phase('SETUP', setupPromisesFn))
    .then(printStatus)
    .then(() => phase('STRATEGIES', () => promisePool.start()))
    .catch(err => {
      console.error(err);
      strategies.showLastQuery(strategyTable);
      exitCode = 1;
    })
    .finally(() => phase('SHUTDOWN', shutdownConnections))
    .then(() => {
      const endTime = new Date().getTime();
      // Because strategies run in parallel, you can not time this
      // by adding their times.  Rather we time the overall execution
      // process.
      let totalElapsed = (endTime - startTime);
      console.log(`BENCHMARK_ELAPSED=${totalElapsed}\n`);
    })
    .then(() => phase('REPORT', () => strategies.report(strategyTable)))
    .then(() => process.exit(exitCode));
};

main();
