const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');

class AggregateReadStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'AggregateReadStrategy';
    }

    run(driver) {
        const f = (s = driver.session()) => s.readTransaction(tx => tx.run(`
            MATCH (v:NAryTree) 
            WHERE id(v) % $r = 0
            RETURN min(v.val), max(v.val), stdev(v.val), count(v.val)`, 
            { r: this.randInt(13) }));
        
        return this.time(f);
    }
}

module.exports = AggregateReadStrategy;