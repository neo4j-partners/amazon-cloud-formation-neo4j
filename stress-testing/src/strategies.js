/**
 * Library of strategies for easy inclusion.
 */
const NAryTreeStrategy = require('./write-strategy/NAryTreeStrategy');
const FatNodeAppendStrategy = require('./write-strategy/FatNodeAppendStrategy');
const MergeWriteStrategy = require('./write-strategy/MergeWriteStrategy');
const RawWriteStrategy = require('./write-strategy/RawWriteStrategy');
const StarWriteStrategy = require('./write-strategy/StarWriteStrategy');
const IndexHeavyStrategy = require('./write-strategy/IndexHeavyStrategy');
const LockTortureStrategy = require('./write-strategy/LockTortureStrategy');
const RandomLinkageStrategy = require('./write-strategy/RandomLinkageStrategy');
const AggregateReadStrategy = require('./read-strategy/AggregateReadStrategy');
const MetadataReadStrategy = require('./read-strategy/MetadataReadStrategy');
const LongPathReadStrategy = require('./read-strategy/LongPathReadStrategy');
const RandomAccessReadStrategy = require('./read-strategy/RandomAccessReadStrategy');

const builder = sessionPool => ({
    // WRITE STRATEGIES
    naryWrite: new NAryTreeStrategy({ n: 2, sessionPool }),
    fatnodeWrite: new FatNodeAppendStrategy({ sessionPool }),
    mergeWrite: new MergeWriteStrategy({ n: 1000000, sessionPool }),
    rawWrite: new RawWriteStrategy({ n: 10, sessionPool }),
    randomLinkage: new RandomLinkageStrategy({ n: 1000000, sessionPool }),
    starWrite: new StarWriteStrategy({ sessionPool }),
    indexHeavy: new IndexHeavyStrategy({ sessionPool }),
    lockTorture: new LockTortureStrategy({ sessionPool }),

    // READ STRATEGIES
    aggregateRead: new AggregateReadStrategy({ sessionPool }),
    metadataRead: new MetadataReadStrategy({ sessionPool }),
    longPathRead: new LongPathReadStrategy({ sessionPool }),
    randomAccess: new RandomAccessReadStrategy({ sessionPool }),
});

const report = strategyTable => {
    console.log('Strategy report');

    Object.keys(strategyTable).forEach(strategy => {
        const strat = strategyTable[strategy];

        if (strat.countRuns() > 0) {
            strat.summarize();
        }
    });
};

const showLastQuery = strategyTable => {
    Object.keys(strategyTable).forEach(strat => {
        if (strategyTable[strat].lastQuery) {
            console.log(strat, 'last query');
            console.log(strategyTable[strat].lastQuery);
            console.log(strategyTable[strat].lastParams);
        }
    });
};

module.exports = {
    builder, report, showLastQuery,
};