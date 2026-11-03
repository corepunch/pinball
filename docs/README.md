# Documentation map

Start with the root documents, then read the guide for the system being changed.

| Document | Read it for |
| --- | --- |
| [README](../README.md) | Product overview, running the app, controls, levels, Game Center setup |
| [AGENTS](../AGENTS.md) | Current agent instructions, presentation decisions, invariants, resource limits |
| [Architecture](../ARCHITECTURE.md) | Ownership, dependencies, frame/thread model, coordinates, data pipeline |
| [Contributing](../CONTRIBUTING.md) | Exact generation/build/test/capture workflow and environment limits |
| [Scenes](../Art/SCENES.md) | XML format, prefab modifiers, layout rules, shared/base inheritance |
| [Model guide](../Art/MODEL_GUIDE.md) | Hardware/material roles, ball deformation, gate geometry, mesh verification |
| [UI guide](../Art/UI_GUIDE.md) | Overlay/HUD, authored control states, safe areas, input and UI verification |
| [Skin guide](../Art/SKIN_GUIDE.md) | Skin assets, atlas resources, palettes, export and render tools |
| [Analysis tools — Russian](analysis-tools.ru.md) | Production-physics probes, reports, heatmaps, persistent runner, comparisons |
| [Level-design workflow — Russian](level-design-workflow.ru.md) | Shot/return planning, experiments, quality gates, design acceptance |
| [Layout research](../Art/TABLE_LAYOUT_GUIDE.md) | Reference reasoning and earlier board measurements/proposals |
| [First Light shot plan](aurora.md) | Current Aurora routes, rules, clearances and regression suite |
| [Space Cadet reference](space-cadet-reference.md) | Measured JP VPX lane/flipper proportions, launcher sensors, and scripted board logic |

The research/workflow documents contain historical examples and proposed tooling. Check current
source and supported commands before using them: only `aurora` is shipped today, and old table
names, measurements, or a referenced tool may no longer exist. Current user instructions and
implemented contracts in AGENTS/ARCHITECTURE take precedence over historical proposals.

Keep documentation near its owner: agent rules in AGENTS, system behavior in ARCHITECTURE,
commands in CONTRIBUTING, detailed visual/authoring guidance in Art, and analysis/design workflows
here. Link between documents instead of copying long instructions. Update docs in the same change
as behavior; do not add per-agent memory files containing duplicate or obsolete decisions.
