const Strategy = require('./Strategy');
const Promise = require('bluebird');

class WritePropertyDataStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'WritePropertyDataStrategy';
        this.label = props.label;
    }

    setup(driver) {
        const queries = [
            'CREATE INDEX ON :Node(id)',
            'FOREACH (id IN range(0,10000) | MERGE (:Node {id:id}));',
        ];
        
        const session = driver.session();
        return Promise.map(queries, query => session.run(query))
            .then(() => session.close());
    }

    run(driver) {
        if (!this.session) {
            this.session = driver.session();
        }

        const p = this.randInt(10000);
        const r = p - 1000;

        const data = [];
        for (let i = 0; i < 100; i++) {
            data.push(uuid.v4());
        }

        return session.run(`
          MATCH (a:Node) WHERE a.id >= $r and a.id <= $p
          WITH a LIMIT 100
          SET a.list${randInt(100)} = $data SET a:WriteArray
          RETURN count(a);
        `, { data, r, p });
    }
}

module.exports = WritePropertyDataStrategy;