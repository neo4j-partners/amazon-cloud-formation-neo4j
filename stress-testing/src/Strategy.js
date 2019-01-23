const uuid = require('uuid');
const randomstring = require('randomstring');
const _ = require('lodash');

class Strategy {
    constructor(props) {
        this.name = 'Undefined';
        this.props = props;
        this.timings = [];
    }

    setup(driver) { 
        this.driver = driver;
        return Promise.resolve(true); 
    }

    getName() { return this.name; }
    run(driver) { 
        return Promise.reject('Override me in subclass');
    }

    randInt(max) {
        return Math.floor(Math.random() * Math.floor(max));
    }

    getTimings() {
        return this.timings;
    }

    summarize() {
        const runs = this.timings.length;
        const elapsedArr = this.timings.map(t => t.elapsed);
        const avgV = elapsedArr.reduce((a, b) => a + b, 0) / runs || 0;
        const minV = elapsedArr.reduce((min, p) => p < min ? p : min, elapsedArr[0] || 0);
        const maxV = elapsedArr.reduce((max, p) => p > max ? p : max, elapsedArr[0] || 0);

        console.log(`${this.name}: ${runs} runs avg ${avgV.toFixed(2)} ms min ${minV} ms max ${maxV} ms\n`);
    }

    time(somePromiseFunc, data={}) {
        const start = new Date().getTime();

        const session = this.driver.session();

        return somePromiseFunc(session)
            .then(result => {
                const end = new Date().getTime();
                const elapsed = end - start;
                this.timings.push(_.merge({ elapsed }, data));
            })
            .finally(() => session.close());
    }

    randString(len) {
        return randomstring.generate(len);
    }
}

module.exports = Strategy;