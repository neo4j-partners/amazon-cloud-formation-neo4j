const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');

class MetadataReadStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'MetadataReadStrategy';
    }

    setup(driver) {
        return Promise.resolve();
    }

    run(driver) {
        if (!this.session) {
            this.session = driver.session();
        }

        return this.session.run(`
            match (n) return distinct(labels(n)), count(n)`, {})
    }
}

module.exports = MetadataReadStrategy;