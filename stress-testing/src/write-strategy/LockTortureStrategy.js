const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');
const faker = require('faker');

const MAX_STAR_SIZE = 100;

/**
 * This strategy is intended to be run with some concurrency, and it
 * intentionally creates situations where the same node is going to get
 * locked and modified by different concurrent queries.
 */
class LockTortureStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'LockTortureStrategy';
        this.n = props.n || 5;
    }

    setup(driver) {
        super.setup(driver);
        const session = driver.session();

        // Set up some basic nodes and index.
        const queries = [
            'CREATE INDEX ON :LockTorture(id)',
            `UNWIND range(1, ${this.n}) as id MERGE (l:LockTorture {id: id })`,
        ];

        return Promise.map(queries, q => session.run(q))
            .then(() => session.close());
    }
    
    run(driver) {
        const id1 = this.randInt(this.n);
        const id2 = this.randInt(this.n);

        const p1Name = `prop${this.randInt(1000)}`;
        const p2Name = `prop${this.randInt(1000)}`;

        const q = `
            MATCH 
                (l1:LockTorture { id: $id1 }), 
                (l2:LockTorture { id: $id2 })
                OPTIONAL MATCH (l1)-[r:related_to]->(l2)
            WHERE id(r) % 11 = 0
            WITH l1, l2, r
                CREATE (l1)-[:related_to]->(l2)
                SET l1.${p1Name} = $p1Name,
                    l2.${p2Name} = $p2Name
                DELETE r
            RETURN 1;
        `;

        const params = {
            id1, id2, p1Name, p2Name,
        };

        const f = (s) => s.writeTransaction(tx => tx.run(q, params));
        return this.time(f);
    }
}

module.exports = LockTortureStrategy;