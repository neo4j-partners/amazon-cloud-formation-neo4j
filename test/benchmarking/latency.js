const yargs = require('yargs');
const neo4j = require('neo4j-driver').v1;
const Promise = require('bluebird');

const argv = yargs.argv;

if (!argv.p || !argv.a) {
    console.log("Usage: latency.js -a address -u username -p password");
    process.exit(1);
}

const start = new Date().getTime();
let error;
let end;

const getLatency = () => {
    const driver = neo4j.driver(argv.a,
        neo4j.auth.basic(argv.u || 'neo4j', argv.p));

    const session = driver.session();
    return session.run('RETURN 1')
        .then(() => {
            end = new Date().getTime();
            error = null;
        })
        .catch(err => {
            end = new Date().getTime();
            console.error(err);
            error = err;
        })
        .then(() => {
            session.close();
            driver.close();
            return {
                latency: (end - start),
                error,
            };
        });
};

return Promise.map([0,1,2,3,4,5,6,7,8,9,10], getLatency, { concurrency: 2 })
    .then(allResults => {
        const errors = allResults.filter(r => r.error).length;

        const latencies = allResults.map(r => r.latency);
        const latency = latencies.reduce((a,b) => a+b, 0) / latencies.length;

        console.log(`BENCHMARK_LATENCY=${latency}`);
        console.log(`BENCHMARK_LATENCIES=${latencies.join(',')}`);
        console.log(`BENCHMARK_LATENCY_ERRORS=${errors}`);
        if (errors) {
            process.exit(1);
        }

        process.exit(0);
    });