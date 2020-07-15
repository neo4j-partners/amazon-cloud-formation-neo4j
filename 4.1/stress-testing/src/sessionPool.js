const genericPool = require('generic-pool');
let sessionPool = null;

module.exports = {
    getPool: (driver, poolSize) => {
        if (sessionPool) {
            return sessionPool;
        }

        // How to create/destroy sessions.
        const factory = {
            create: () => {
                const s = driver.session();
                return s;
            },
            destroy: session => {
                return session.close();
            },
            validate: session =>
                session.run('RETURN 1;', {})
                    .then(results => true)
                    .catch(err => false),
        };

        const sessionPoolOpts = { min: 1, max: poolSize };
        console.log('Creating session pool with ', sessionPoolOpts);
        sessionPool = genericPool.createPool(factory, sessionPoolOpts);
        sessionPool.on('factoryCreateError', err => console.log('SESSION POOL ERROR', err));
        sessionPool.on('factoryDestroyError', err => console.error('SESSION POOL DESTROY ERROR', err));
        sessionPool.start();

        return sessionPool;
    },

    destroy: () => {
        return sessionPool.drain()
            .then(() => sessionPool.clear())
            .catch(err => {
                console.error('Some error draining/clearing pool', err);
            })
            .finally(() => {
                sessionPool = null;
            });
    },
};