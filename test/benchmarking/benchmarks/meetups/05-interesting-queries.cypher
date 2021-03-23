/*
 * Most popular topics
 */
MATCH (g:Group)-[:TOPIC]-(t:Topic)
RETURN t.name, count(g) as groups
ORDER BY groups DESC
limit 100;

/**
 * Who brings the most guests?
 */
MATCH (r:RSVP)-[:MEMBER]->(m:Member)
WHERE r.guests > 5
RETURN m.name, sum(r.guests) as totalGuests
ORDER BY totalGuests DESC limit 10;

/**
 * Which venue hosts the most meetups?
 */
MATCH (v:Venue)<-[:LOCATED_AT]-(e:Event)
WHERE v.name is not null
RETURN v.name, v.location, count(e) as events
ORDER BY events desc 
limit 10;

/**
 * Pick a random venue. What meetups has it held?
 */
MATCH (v:Venue)
WHERE v.name is not null
WITH collect(v) as venues
WITH apoc.coll.randomItem(venues) as venue
MATCH (venue)<-[:LOCATED_AT]-(e:Event)<-[:HELD]-(g:Group),
 (e)-[:EVENT]-(r:RSVP)
RETURN venue.name, venue.location, e.name, g.name, count(r) as RSVPs
LIMIT 10;

/**
 * Pick some random venues and find the shortest path between
 * them by topics.
 */
MATCH (v:Venue)
WHERE v.name is not null
WITH collect(v) as venues
WITH apoc.coll.randomItem(venues) as v1,
     apoc.coll.randomItem(venues) as v2
MATCH p=shortestPath((v1)-[*]-(v2))
RETURN p;

/**
 * Find shortest path between a triangle of three random members
 */
MATCH (m:Member)
WITH collect(m) as members
WITH apoc.coll.randomItem(members) as m1,
     apoc.coll.randomItem(members) as m2,
     apoc.coll.randomItem(members) as m3
MATCH p1=shortestPath((m1)-[*]-(m2)),
      p2=shortestPath((m2)-[*]-(m3)),
      p3=shortestPath((m1)-[*]-(m3))
RETURN p1, p2, p3;

/**
 * Find shortest path between two random topics.
 */
MATCH (t:Topic)
WITH collect(t) as topics
WITH apoc.coll.randomItem(topics) as t1,
     apoc.coll.randomItem(topics) as t2
MATCH p=shortestPath((t1)-[*]-(t2))
RETURN p;

/* 
 * Future Richmond Meetups within 10 miles of downtown
 */
WITH 
    point({ latitude: 37.5407246, longitude: -77.4360481 }) as RichmondVA,
    32186.9 as TenMiles   /* 10 mi expressed in meters */
MATCH (v:Venue)<-[:LOCATED_AT]-(e:Event)-[:HELD]-(g:Group) 
WHERE 
   distance(v.location, RichmondVA) < TenMiles AND
   e.time > datetime()
RETURN g.name as GroupName, e.name as EventName, e.time as When, v.name as Venue limit 10;

WITH 
  rand() * 90 * (CASE WHEN rand() <= 0.5 THEN 1 ELSE -1 END) as randLat,
  rand() * 90 * (CASE WHEN rand() <= 0.5 THEN 1 ELSE -1 END) as randLon
WITH point({ latitude: randLat, longitude: randLon }) as randomLocation
MATCH (v:Venue)-[:NEAR]->(city:City)-[:IN]->(c:Country)
RETURN 
    city.name as City, 
    c.name as Country, 
    v.name as Venue, 
    v.location as VenueLocation, 
    randomLocation as RandomLocation,
    distance(v.location, randomLocation) as DistanceInMeters
ORDER BY distance(v.location, randomLocation) ASC
LIMIT 1;

/*
 * Pick a random topic and show which users attend the most Meetups
 * in that topic area.
 */
MATCH (t:Topic) 
WITH collect(t) as topics 
WITH apoc.coll.randomItem(topics) as targetTopic
MATCH (targetTopic)-[:TOPIC]-(g:Group)-[:HELD]-(e:Event)<-[:EVENT]-(r:RSVP)-[:MEMBER]-(member:Member)
RETURN targetTopic.name as topic, member.name as member, count(r) as RSVPs
ORDER BY RSVPs DESC limit 10;

/*
 * Let's go dancing in Manhattan on a particular day.
 */
WITH 
   point({ latitude: 40.758896, longitude: -73.985130 }) as TimesSquareManhattan,
   32186.9 as TenMiles
MATCH (v:Venue)<-[:LOCATED_AT]-(e:Event),
      (e)-[:HELD]-(g:Group),
      (g)-[:TOPIC]->(t:Topic),
      (e)<-[:EVENT]-(r:RSVP)
WHERE e.time >= datetime("2018-09-06T00:00:00Z") AND
      e.time <= datetime("2018-09-06T23:59:59Z") AND
      distance(v.location, TimesSquareManhattan) < TenMiles AND
      v.name is not null AND
      t.name =~ '(?i).*dancing.*'
RETURN 
    g.name as GroupName, 
    collect(distinct t.name) as topics, 
    e.name as EventName, 
    count(r) as RSVPs, 
    e.time as When, 
    v.name as Venue 
ORDER BY RSVPs DESC
LIMIT 100;