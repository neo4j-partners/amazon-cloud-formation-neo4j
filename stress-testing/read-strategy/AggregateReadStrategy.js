const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');

class AggregateReadStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'AggregateReadStrategy';
    }

    setup(driver) {
        return Promise.resolve();
    }

    run(driver) {
        if (!this.session) {
            this.session = driver.session();
        }

        return this.session.run(`
            MATCH (v:NAryTree) 
            WHERE id(v) % $r = 0
            RETURN min(v.val), max(v.val), stdev(v.val), count(v.val)`, 
            { r: this.randInt(13) });
    }
}

module.exports = AggregateReadStrategy;