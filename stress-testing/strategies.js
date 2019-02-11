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

const strategies = {
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
};

module.exports = strategies;