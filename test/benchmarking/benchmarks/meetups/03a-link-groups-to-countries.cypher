MATCH (g:Group)
WITH toUpper(g.country) as iso2, g
MATCH (c:Country { iso2: iso2 })
MERGE (g)-[r:IN]->(c)
RETURN count(r);