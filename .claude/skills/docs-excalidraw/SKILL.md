---
name: excalidraw
description: Generate Excalidraw JSON format diagrams for documentation, architecture diagrams, flowcharts, and visual explanations of AWS/Neo4j infrastructure.
---

# Excalidraw Diagram Generator

Generate valid Excalidraw JSON for diagrams.

## JSON Schema Structure

```json
{
  "type": "excalidraw",
  "version": 2,
  "source": "https://excalidraw.com",
  "elements": [],
  "appState": {
    "gridSize": 20,
    "viewBackgroundColor": "#ffffff"
  },
  "files": {}
}
```

## Element Types

### Base Properties (all elements)

```json
{
  "id": "unique-id",
  "type": "rectangle|ellipse|diamond|text|arrow|line",
  "x": 0,
  "y": 0,
  "width": 100,
  "height": 50,
  "angle": 0,
  "strokeColor": "#1e1e1e",
  "backgroundColor": "transparent",
  "fillStyle": "solid",
  "strokeWidth": 2,
  "strokeStyle": "solid",
  "roughness": 1,
  "opacity": 100,
  "seed": 12345,
  "version": 1,
  "isDeleted": false,
  "groupIds": [],
  "frameId": null,
  "roundness": { "type": 3 },
  "boundElements": null
}
```

### Text Elements

```json
{
  "type": "text",
  "text": "Label",
  "fontSize": 20,
  "fontFamily": 1,
  "textAlign": "center",
  "verticalAlign": "middle",
  "containerId": null
}
```

`fontFamily`: 1=Virgil (hand-drawn), 2=Helvetica, 3=Cascadia (code)

### Arrow Elements

```json
{
  "type": "arrow",
  "points": [[0, 0], [100, 0]],
  "startBinding": null,
  "endBinding": null,
  "startArrowhead": null,
  "endArrowhead": "arrow"
}
```

### Binding Arrows to Shapes

```json
{
  "startBinding": {
    "elementId": "target-shape-id",
    "focus": 0,
    "gap": 5
  }
}
```

## Style Values

| Property | Values |
|----------|--------|
| fillStyle | "solid", "hachure", "cross-hatch" |
| strokeStyle | "solid", "dashed", "dotted" |
| roughness | 0 (architect), 1 (artist), 2 (cartoonist) |

## Color Palette

```
Stroke: #1e1e1e (black), #e03131 (red), #2f9e44 (green), #1971c2 (blue)
Background: transparent, #ffc9c9 (light red), #b2f2bb (light green),
            #a5d8ff (light blue), #ffec99 (light yellow), #d0bfff (light purple)
```

## Generation Workflow

1. Plan layout on a grid (increments of 50-100px)
2. Create shapes first with unique IDs
3. Add text elements
4. Add connections with bindings
5. Update boundElements on connected shapes

## ID Generation

Use descriptive IDs: `"box-component"`, `"arrow-a-to-b"`, `"label-title"`

## Output

Save as `.excalidraw` file (JSON with .excalidraw extension) in `docs/images/`.

## Placeholder Format

In Markdown docs, use this format to mark where diagrams are needed:

```markdown
<!-- DIAGRAM: Diagram Title Here -->
```

Optionally include ASCII art for reference:

````markdown
<!-- DIAGRAM: CE Deployment Architecture -->
```text
+------------------+     +------------------+
|   CloudFormation |---->|   EC2 Instance   |
+------------------+     +------------------+
```
````
