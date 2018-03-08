const uuid = require('uuid');
const randomstring = require('randomstring');

class Strategy {
    constructor(props) {
        this.name = 'Undefined';
        this.props = props;
    }

    setup(driver) { return Promise.resolve(true); }

    getName() { return this.name; }
    run(driver) { 
        return Promise.reject('Override me in subclass');
    }

    randInt(max) {
        return Math.floor(Math.random() * Math.floor(max));
    }

    randString(len) {
        return randomstring.generate(len);
    }
}

module.exports = Strategy;