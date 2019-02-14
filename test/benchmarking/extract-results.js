const yargs = require('yargs');
const Promise = require('bluebird');
const fs = require('fs');
const _ = require('lodash');
const createCsvWriter = require('csv-writer').createObjectCsvWriter;

const REQUIRED = [
    'BENCHMARK', 'DATE', 'TAG', 'ELAPSED', 'EXECUTION_TIME',
    'LOG_FILE', 'PROVIDER', 'EXIT_CODE', 'LATENCY', 'LATENCIES', 
    'LATENCY_ERRORS',
];

const isRequired = key => REQUIRED.indexOf(key) > -1;
const isSettingHeader = h => h.match(/^SETTING_/);
const isBenchmarkSpecific = h => !isRequired(h) && !isSettingHeader(h);

// A record is valid if all required fields are present.
const isValid = entry => 
    REQUIRED.map(k => entry[k]).filter(x => x).length === REQUIRED.length;

const extractFile = filename => {
    console.log("Opening ", filename);
    const lines = fs.readFileSync(filename).toString().split("\n");

    const objects = lines.filter(l => l.match(/^BENCHMARK_/))
        .map(l => l.replace(/^BENCHMARK_/, ''))
        .map(kvPair => {
            const i = kvPair.indexOf('=');
            if (i === -1) {
                console.error('Invalid kvpair ', kvPair);
                return null;
            }

            const key = kvPair.substring(0, i);
            const val = kvPair.substring(i+1);
            return { [key]: val };           
        });

    return _.merge(...objects);
}

const writeCSV = (filename, records) => {

    const allPossibleSettings = _.uniq(_.flatten(records.map(r => 
        Object.keys(r).filter(isSettingHeader))));
    const allPossibleBenchmarkFields = _.uniq(_.flatten(records.map(r =>
        Object.keys(r).filter(isBenchmarkSpecific))));

    // Match format for CSV writer.
    const makeHeader = h => ({ id: h, title: h });

    // To get the header we have to take the union of all valid fields
    // in the records.  We always want required fields first, then 
    // settings, then benchmark specific stuff.
    const header = REQUIRED.map(makeHeader)
        .concat(allPossibleSettings.map(makeHeader))
        .concat(allPossibleBenchmarkFields.map(makeHeader));

    const csvWriter = createCsvWriter({
        path: filename,
        header,
    });
    
    return csvWriter.writeRecords(records);
}

console.log(yargs.argv);

const allObjects = yargs.argv._.map(extractFile);
console.log('Got ', allObjects.length);
const valid = allObjects.filter(isValid);
console.log('Valid: ', valid.length);

const filename = `results-${new Date().getTime()}.csv`;

writeCSV(filename, valid)
    .then(results => {
        console.log('Wrote results to ', filename, results);
    })
    .catch(err => {
        console.error('Failed to write CSV', err);
    });
