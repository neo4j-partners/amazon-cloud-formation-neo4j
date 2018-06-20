const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');

class RawWriteStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'MergeWriteStrategy';
        this.n = props.n || 10;
    }

    setup(driver) {
        return Promise.resolve(true);
        const queries = [
            'CREATE INDEX ON :MergeNode(id)',
            'FOREACH (id IN range(0,10000) | MERGE (:MergeNode {id:id}));',
        ];
        
        const session = driver.session();
        return Promise.map(queries, query => session.run(query))
            .then(() => session.close());
    }

    run(driver) {
        if (!this.session) {
            this.session = driver.session();
        }

        this.lastQuery = `
        FOREACH (id IN range(0,${this.n}) | 
            CREATE (:RawWriteNode {id:id * rand(), uuid: $uuid})-[:rawrite]->(:RawWriteNode { id:id * rand(), uuid: $uuid })
        );`;
        
        this.lastParams = { uuid: uuid.v4() };
        const f = () => this.session.run(this.lastQuery, this.lastParams);
        return this.time(f);
    }
}

module.exports = RawWriteStrategy;