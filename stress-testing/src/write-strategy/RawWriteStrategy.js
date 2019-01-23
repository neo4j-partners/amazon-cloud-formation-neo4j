const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');

class RawWriteStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'MergeWriteStrategy';
        this.n = props.n || 10;
    }

    // setup(driver) {
    //     return Promise.resolve(true);
    //     const queries = [
    //         'CREATE INDEX ON :MergeNode(id)',
    //         'FOREACH (id IN range(0,10000) | MERGE (:MergeNode {id:id}));',
    //     ];
        
    //     const session = driver.session();
    //     return Promise.map(queries, query => session.run(query))
    //         .then(() => session.close());
    // }

    run(driver) {
        this.lastQuery = `
        FOREACH (id IN range(0,${this.n}) | 
            CREATE (:RawWriteNode {
                id:id * rand(), 
                uuid: $uuid,
                f1: rand(), f2: rand(), f3: rand(), f4: rand(), f5: rand(),
                created: datetime()
            })-[:rawrite]->(:RawWriteNode { 
                id:id * rand(), 
                uuid: $uuid,
                f1: rand(), f2: rand(), f3: rand(), f4: rand(), f5: rand(),
                created: datetime()
            })
        );`;
        
        this.lastParams = { uuid: uuid.v4() };
        const f = (s = driver.session()) => s.writeTransaction(tx => tx.run(this.lastQuery, this.lastParams));
        return this.time(f);
    }
}

module.exports = RawWriteStrategy;