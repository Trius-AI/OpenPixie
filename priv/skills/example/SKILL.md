---
description: Example skill for demonstration
always: false
tags: [example, demo]
---

# Example Skill

This is an example skill. When loaded, it provides context about how to use the skill system.

## Usage

Skills are Markdown files with YAML frontmatter. The frontmatter contains metadata:
- `description`: A one-line description of the skill
- `always`: If true, the skill is always loaded into the system prompt
- `tags`: An array of tags for search and discovery

The body of the SKILL.md file contains the instructions that will be provided to the assistant when this skill is loaded.