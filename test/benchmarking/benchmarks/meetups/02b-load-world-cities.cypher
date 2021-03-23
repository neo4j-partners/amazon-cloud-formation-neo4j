USING PERIODIC COMMIT
LOAD CSV WITH HEADERS 
FROM 'https://storage.googleapis.com/meetup-data/worldcities.csv' AS line

MERGE (country:Country {
    name: coalesce(line.country, ''),
    iso2: coalesce(line.iso2, ''),
    iso3: coalesce(line.iso3, '')    
})

MERGE (c:City {
    id: coalesce(line.id, ''),
    name: coalesce(line.city, ''),
    asciiName: coalesce(line.city_ascii, ''),
    adminName: coalesce(line.admin_name, ''),
    capital: coalesce(line.capital, ''),
    location: point({
        latitude: toFloat(coalesce(line.lat, '0.0')),
        longitude: toFloat(coalesce(line.lng, '0.0'))
    }),
    population: coalesce(line.population, 0)
})

MERGE (c)-[:IN]->(country);