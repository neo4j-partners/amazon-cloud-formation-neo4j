const uuid = require('uuid');
const randomstring = require('randomstring');

export default class Strategy {
    constructor(props) {
        this.name = 'Undefined';
        this.props = props;
    }

    getName() { return this.name; }
    run() { 
        return Promise.reject('Override me in subclass');
    }

    randInt(max) {
        return Math.floor(Math.random() * Math.floor(max));
    }

    randString(len) {
        return randomstring.generate(len);
    }
}