const Strategy = require('../Strategy');
const Promise = require('bluebird');
const uuid = require('uuid');
const faker = require('faker');

const MAX_STAR_SIZE = 100;

class IndexHeavyStrategy extends Strategy {
    constructor(props) {
        super(props);
        this.name = 'StarWriteStrategy';
        this.n = props.n || MAX_STAR_SIZE;
    }

    setup(driver) {
        super.setup(driver);
        const session = driver.session();

        const queries = [
            'CREATE INDEX ON :Customer(id)',
            'CREATE INDEX ON :Customer(name)',
            'CREATE INDEX ON :Customer(email)',
            'CREATE INDEX ON :Customer(username)',
            'CREATE INDEX ON :Customer(created)',
            'CREATE INDEX ON :Address(location)',
            'CREATE INDEX ON :Address(created)',
            'CREATE INDEX ON :Address(zip)',
            'CREATE INDEX ON :Address(city)',
            'CREATE INDEX ON :Address(cityPrefix)',
            'CREATE INDEX ON :Address(streetName)',
            'CREATE INDEX ON :Address(streetAddress)',
            'CREATE INDEX ON :Address(streetPrefix)',
            'CREATE INDEX ON :Address(secondaryAddress)',
            'CREATE INDEX ON :Address(country)',
            'CREATE INDEX ON :Address(county)',
            'CREATE INDEX ON :Address(countryCode)',
            'CREATE INDEX ON :Address(state)',
            'CREATE INDEX ON :Address(stateAbbr)',
        ];

        return Promise.map(queries, q => session.run(q))
            .then(() => session.close());
    }
    
    run(driver) {
        const id = uuid.v4();
        const q = `
            MERGE (c:Customer { username: $username })
                ON CREATE SET
                c.id = $id,
                c.name = $name, 
                c.email = $email,
                c.created = datetime()
            
            WITH c
            
            CREATE (a:Address {
                location: point({ latitude: $latitude, longitude: $longitude }),
                created: datetime(),
                zip: $zipCode, city: $city,
                cityPrefix: $cityPrefix, 
                streetName: $streetName,
                streetAddress: $streetAddress,
                streetPrefix: $streetPrefix,
                secondaryAddress: $secondaryAddress,
                country: $country,
                county: $county,
                countryCode: $countryCode,
                state: $state, stateAbbr: $stateAbbr
            })
            CREATE (c)-[:address]->(a)
        `;        

        const params = {
            id,
            name: faker.name.findName(),
            username: faker.internet.userName(),
            email: faker.internet.email(),  
        };

        // See: https://www.npmjs.com/package/faker
        const fakeFuncs = [
            'zipCode', 'city', 'cityPrefix',
            'streetName', 'streetAddress', 
            'streetPrefix', 'secondaryAddress',
            'country', 'county', 'countryCode', 
            'state', 'stateAbbr', 
        ];

        params.latitude = Number(faker.address.latitude());
        params.longitude = Number(faker.address.longitude());

        fakeFuncs.forEach(f => {
            console.log('fake',f);
            params[f] = faker.address[f]();
        });

        const f = (s = driver.session()) => 
            s.writeTransaction(tx => tx.run(q, params)).finally(() => s.close());
        return this.time(f);
    }
}

module.exports = IndexHeavyStrategy;