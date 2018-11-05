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
            const choice = i % 3;

            if (i === 0) {
                query = "CALL db.labels()";
            } else if(i === 1) {
                query = "CALL db.propertyKeys()";
            } else {
                query = "CALL okapi.schema()";
            }

            return this.session.run(query, {});
        };
        
        return this.time(f);
    }
}

module.exports = MetadataReadStrategy;