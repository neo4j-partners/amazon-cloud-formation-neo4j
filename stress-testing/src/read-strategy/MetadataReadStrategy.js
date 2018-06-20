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

        const i = this.randInt(50);

        const f = () => {
            let query;
            if (i % 2 === 0) {
                query = "CALL db.labels()";
            } else {
                query = "CALL db.propertyKeys()";
            }

            return this.session.run(query, {});
        };
        
        return this.time(f);
    }
}

module.exports = MetadataReadStrategy;