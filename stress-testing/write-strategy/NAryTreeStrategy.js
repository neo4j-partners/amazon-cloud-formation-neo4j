const Strategy = require('../Strategy');
const Promise = require('bluebird');

class NAryTreeStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.n = props.n;
        this.name = 'NAryTreeStrategy';
    }

    setup(driver) {
        const session = driver.session();

        const queries = [
            "CREATE INDEX ON :NAryTree(val)",
            "CREATE INDEX ON :Leaf(val)",
            "CREATE (a:NAryTree:Leaf { label: 'ROOT', val: 2 })",
        ];

        return Promise.map(queries, query => session.run(query))
            .then(() => session.close());
    }

    run(driver) {
        if (!this.session) {
            this.session = driver.session();
        }

        this.tracker = (this.tracker || 1) + 1;
        this.lastParams = { tracker: this.tracker };

        this.lastQuery = `
            MATCH (p:Leaf)
            WHERE p.val >= $tracker
            WITH p ORDER BY p.val DESC
            LIMIT 10
            WHERE NOT (p)-[:child]->(:NAryTree)
            WITH p
            REMOVE p:Leaf
            ${
                Array.apply(null, { length: this.n }).map((z, idx) => {
                    return `
                        CREATE (p)-[:child]->(i${idx}:NAryTree:Leaf { val: p.val + ${idx + 1} })
                    `
                }).join('\n')
            }
            RETURN p.val;
        `;

        return this.session.run(this.lastQuery, this.lastParams);
    }
}

module.exports = NAryTreeStrategy;