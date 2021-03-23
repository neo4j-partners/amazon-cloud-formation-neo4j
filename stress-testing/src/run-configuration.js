const terminateAfter = require('./termination-condition');

const usage = () => {
    console.log(`
Usage: node stress.js 
   [-a address] 
   [-u username] 
   [-p password] 
   [-n hits] how many total queries to run
   [--ms milliseconds] how many milliseconds to test for
   [--workload /path/to/workload.json] probability table spec
   [--concurrency c] how many concurrent queries to run (default: 10)
   [--checkpoint cn] how often to print results in milliseconds (default: 5000)

You may only specify one of the options --n or --ms.

Username, password, and address for Neo4j will be taken from the environment variables
NEO4J_USER, NEO4J_PASSWORD, and NEO4J_URI if not specified.
`)
    process.exit(1);
};

const defaultProbabilityTable = [
    [0.1, 'fatnodeWrite'],
    [0.2, 'naryWrite'],
    [0.3, 'mergeWrite'],
    [0.4, 'randomLinkage'],
    [0.45, 'starWrite'],
    [0.55, 'indexHeavy'],
    [0.60, 'aggregateRead'],
    [0.695, 'randomAccess'],
    [0.70, 'longPathRead'],
    [1, 'rawWrite'],
];

module.exports = (args) => {
    const badlyConfigured = (
        // User is being inconsistent about when to stop.
        (args.n && args.ms) ||
        // We don't know where to connect...
        (!process.env.NEO4J_URI && !args.a) ||
        // Don't know what password to use...
        (!process.env.NEO4J_PASSWORD && !args.p)
    );

    if (badlyConfigured) {
        usage();
    }

    const probabilityTable = args.workload ? require(args.workload) : defaultProbabilityTable;
    let iterateUntil;
    let runType;

    if (args.n) {
        iterateUntil = terminateAfter.nRuns(args.n);
        runType = 'counted';
    } else if (args.ms) {
        iterateUntil = terminateAfter.timeoutMilliseconds(args.ms);
        runType = 'timed';
    } else {
        iterateUntil = terminateAfter.nRuns(10000);
        runType = 'counted';
    }

    const p = Number(args.concurrency) || Number(process.env.CONCURRENCY);

    const obj = {
        username: args.u || process.env.NEO4J_USER || 'neo4j',
        password: args.p || process.env.NEO4J_PASSWORD,
        address: args.a || process.env.NEO4J_URI,
        probabilityTable,
        runType,
        checkpointFreq: args.checkpoint || process.env.CHECKPOINT_FREQUENCY || 5000,
        concurrency: (!Number.isNaN(p) && p > 0) ? p : 10,
        iterateUntil,
        probabilityTable,
    };

    if (obj.runType === 'counted') {
        obj.n = args.n || 10000;
    } else {
        obj.ms = args.ms || 1000 * 60 * 5; // 5 minutes
    }

    return obj;
};
