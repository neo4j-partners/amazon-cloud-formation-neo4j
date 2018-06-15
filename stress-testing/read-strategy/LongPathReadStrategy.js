const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');

class LongPathReadStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'LongPathReadStrategy';
    }

    setup(driver) {
        return Promise.resolve();
    }

    run(driver) {
        if (!this.session) {
            this.session = driver.session();
        }

        const start = 1 + this.randInt(1000);

        const f = () => this.session.run(`
            MATCH p=(s:NAryTree { val: $start })-[r:child*]->(e:NAryTree { val: $end })
            RETURN count(r)`, 
            { start, end: start + this.randInt(500) });

        return this.time(f);
    }
}

module.exports = LongPathReadStrategy;