const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');

class MergeWriteStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'MergeWriteStrategy';
        this.n = props.n || 100000000;
    }

    setup(driver) {
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
        MERGE (n:MergeNode { id: $id1 }) ON CREATE SET n.uuid = $u1 SET n:SimpleWrite
        MERGE (p:MergeNode { id: $id2 }) ON CREATE SET p.uuid = $u2 SET p:SimpleWrite
        MERGE (z:MergeNode { id: $id3 }) ON CREATE SET z.uuid = $u3 SET z:SimpleWrite
        MERGE (n)-[:link {r: $r, uuid: $u4 }]->(p)
        MERGE (n)-[:otherlink { r: $r2, uuid: $u5 }]->(z)
        RETURN 1;`;
        
        this.lastParams = { 
          r: this.randInt(100000), 
          id1: this.randInt(this.n), 
          id2: this.randInt(this.n), 
          id3: this.randInt(this.n),
          u1: uuid.v4(), u2: uuid.v4(), u3: uuid.v4(), u4: uuid.v4(), u5: uuid.v4(),
          r2: this.randInt(100000),
        };

        const f = () => this.session.run(this.lastQuery, this.lastParams);
        return this.time(f);
    }
}

module.exports = MergeWriteStrategy;