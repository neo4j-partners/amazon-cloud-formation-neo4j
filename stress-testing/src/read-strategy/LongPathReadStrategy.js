const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');

class LongPathReadStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'LongPathReadStrategy';
    }

    run(driver) {
        const start = 1 + this.randInt(1000);

        const f = (s = driver.session()) => s.readTransaction(tx => tx.run(`
            MATCH p=(s:NAryTree { val: $start })-[r:child*]->(e:NAryTree { val: $end })
            RETURN count(r)`, 
            { start, end: start + this.randInt(500) }));

        return this.time(f);
    }
}

module.exports = LongPathReadStrategy;