const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');
const faker = require('faker');

const MAX_STAR_SIZE = 100;

class StarWriteStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'StarWriteStrategy';
        this.n = props.n || MAX_STAR_SIZE;
    }

    run(driver) {
        const id = uuid.v4();
        const q = `
            CREATE (h:Hub { id: $id })
            WITH h
            FOREACH (id IN range(0, $starSize) | MERGE (:Spoke { hub: $id, n: id })-[:hub]->(h))
            RETURN null
        `;

        const params = {
            id, starSize: this.n,
        };

        const f = (s) => s.writeTransaction(tx => tx.run(q, params));
        return this.time(f);
    }
}

module.exports = StarWriteStrategy;