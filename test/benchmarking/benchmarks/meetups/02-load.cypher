CALL apoc.load.json('$file' /* 'file:///Users/davidallen/hax/meetup-dataset/meetup.raw' */) 
yield value 
with value.venue as venueData,
value.member as memberData,
value.event as eventData,
value.group.group_topics as topics,
value as data,
apoc.map.removeKeys(value.group, ['group_topics']) as groupData

MERGE (member:Member { id: memberData.member_id })
   ON CREATE SET 
        member.name = memberData.member_name,
        member.photo = memberData.photo

MERGE (event:Event { id: eventData.event_id })
   ON CREATE SET 
        event.name = eventData.event_name,
        event.time = datetime({ epochMillis: coalesce(eventData.time, 0) }),
        event.url = eventData.event_url

MERGE (group:Group { id: groupData.group_id })
   ON CREATE SET 
        group.name = groupData.group_name,
        group.city = groupData.group_city,
        group.country = groupData.group_country,
        group.state = groupData.group_state,
        group.location = point({
            latitude: groupData.group_lat,
            longitude: groupData.group_lon
        }),
        group.urlname = groupData.group_urlname

MERGE (venue:Venue { id: coalesce(venueData.venue_id, randomUUID()) })
   ON CREATE SET 
        venue.name = venueData.venue_name,
        venue.location = point({
            latitude: venueData.lat,
            longitude: venueData.lon
        })

CREATE (rsvp:RSVP {
    id: coalesce(data.rsvp_id, randomUUID()),
    guests: coalesce(data.guests, 0),
    mtime: datetime({ epochMillis: coalesce(data.mtime, 0) }),
    response: data.response,
    visibility: data.visibility
})

CREATE (rsvp)-[:MEMBER]->(member)
CREATE (rsvp)-[:EVENT]->(event)
CREATE (rsvp)-[:GROUP]->(group)

MERGE (member)-[:RSVP]->(event)
MERGE (event)<-[:HELD]-(group)
MERGE (event)-[:LOCATED_AT]->(venue)

WITH  group, topics
UNWIND topics as tp

MERGE (t:Topic { urlkey: tp.urlkey })
   ON CREATE SET t.name = tp.topic_name

MERGE (group)-[:TOPIC]->(t);
