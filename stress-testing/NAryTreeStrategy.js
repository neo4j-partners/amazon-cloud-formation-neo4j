const Strategy = require('./Strategy');

export default class NAryTreeStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.n = props.n;
    }
}