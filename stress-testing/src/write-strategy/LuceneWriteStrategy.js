const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');
const dimsum = require('dimsum');

class LuceneWriteStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'LuceneWrite';
        this.label = props.label;

        this.jabberwocky = dimsum.configure({ flavor: 'jabberwocky' });
    }

    setup(driver) {
        super.setup(driver);
        const session = driver.session();

        // Set up some basic nodes and index.
        const queries = [
            'CALL db.index.fulltext.createNodeIndex("luceneIndex",["LuceneNode"],["text"])',
        ];

        return Promise.map(queries, q => session.run(q))
            .then(() => session.close());
    }

    run(driver) {
        if (!this.session) {
            this.session = driver.session();
        }

        const p = this.randInt(10000000);
        const r = p - 10000;

        const data = [];
        for (let i = 0; i < 1000; i++) {
            data.push(uuid.v4());
        }

        this.lastQuery = `
            CREATE (:LuceneNode { id: $id1, text: $text1 })
            CREATE (:LuceneNode { id: $id2, text: $text2 })
            CREATE (:LuceneNode { id: $id3, text: $text3 })
            CREATE (:LuceneNode { id: $id4, text: $text4 })
            CREATE (:LuceneNode { id: $id5, text: $text5 })
        `;

        this.lastParams = { 
            id1: uuid.v4(),
            id2: uuid.v4(),
            id3: uuid.v4(),
            id4: uuid.v4(),
            id5: uuid.v4(),
            text1: this.jabberwocky(),
            text2: this.jabberwocky(),
            text3: this.jabberwocky(),
            text4: this.jabberwocky(),
            text5: this.jabberwocky(),            
        };
        
        const f = (s) => s.writeTransaction(tx => tx.run(this.lastQuery, this.lastParams));
        return this.time(f);
    }
}

module.exports = LuceneWriteStrategy;