const Strategy = require('../Strategy');

class RandomAccessReadStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'RandomAccessReadStrategy';
        this.prime = props.prime || 1093;
        this.limit = props.limit || 50;
    }

    run(driver) {
        const nth = Math.floor(Math.random() * this.prime) + 1;
        const skip = Math.floor(Math.random() * 1000) + 1;

        const f = (s = driver.session()) => s.readTransaction(tx => tx.run(`
            MATCH (node)
            WHERE id(node) % $prime = $nth
            RETURN keys(node)
            SKIP $skip LIMIT $limit`,
            { prime: this.prime, nth, skip, limit: this.limit }));
        
        return this.time(f);
    }
}

module.exports = RandomAccessReadStrategy;