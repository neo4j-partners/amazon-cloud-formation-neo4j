const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');

class MetadataReadStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'MetadataReadStrategy';
    }

    run(driver) {
        const i = this.randInt(50);

        const f = (s = driver.session()) => {
            let query;
            const choice = i % 3;

            if (i === 0) {
                query = "CALL db.labels()";
            } else if(i === 1) {
                query = "CALL db.propertyKeys()";
            } else {
                query = "CALL okapi.schema()";
            }

            return s.readTransaction(tx => tx.run(query, {}));
        };
        
        return this.time(f);
    }
}

module.exports = MetadataReadStrategy;