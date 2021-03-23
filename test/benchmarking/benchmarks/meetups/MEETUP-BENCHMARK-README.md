# meetup-dataset

Tools and utilities for loading data from the [Meetup RSVP Stream](https://www.meetup.com/meetup_api/docs/stream/2/rsvps/) into Neo4j, and performing datetime/location based
analyses in Neo4j

# How to use This

## Fetching raw data from the API

To fetch data from the RSVP stream, it's this easy:

```
curl -i https://stream.meetup.com/2/rsvps > meetup.raw
```

Let that run as long as you like.  Volume is something like a handful (< 12) a second is what I typically see.

Don't forget to strip the first few lines out of this file (HTTP headers that aren't data)

I then split the file into segments like this:

```
split -l 10000 meetup.raw segments/mybatch
```

This creates a series of batched load files, called `segments/mybatchxaa`, `segments/mybatchxab`, and so forth.

## Prepping the database

* Create a fresh database
* Install APOC, and set `apoc.file.import.enabled=true`
* Create indexes: `cat 01-index.cypher | cypher-shell -a localhost -u neo4j -p secret`
* Load segments: `./load-all.sh`

## Run Queries as desired

Sample cypher is provided in the cypher files to show you what you can do with this.

