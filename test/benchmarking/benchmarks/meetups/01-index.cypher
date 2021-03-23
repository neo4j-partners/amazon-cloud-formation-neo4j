CREATE INDEX ON :Member(id);

CREATE INDEX ON :Event(id);
CREATE INDEX ON :Event(time);
CREATE INDEX ON :Event(location);

CREATE INDEX ON :Group(id);
CREATE INDEX ON :Group(location);

CREATE INDEX ON :Venue(id);
CREATE INDEX ON :Venue(location);
CREATE INDEX ON :RSVP(id);
CREATE INDEX ON :Topic(urlkey);

CREATE INDEX ON :City(name);
CREATE INDEX ON :City(location);
CREATE INDEX ON :City(population);

CREATE INDEX ON :Country(iso2);
CREATE INDEX ON :Country(name);