# World Model — Dependency-Aware Self-Modification

> **Living document — maintained by the Guardian during self-improvement.**
> Describes the dependency graph, behavioral contracts, and risk assessment
> that guide safe self-modification.

---

## 1. Overview

The World Model gives the self-modification system **predictive understanding** of what a code change affects before making it. It provides:

- **Dependency graph** — which modules call which, derived from source analysis
- **Impact assessment** — before each `self_improve`, the world model evaluates risk
- **LLM context** — dependency data injected into the system prompt during scheduled mode
- **Post-change refresh** — the graph is rebuilt after every self-modification

## 2. Architecture

```
openpixie_world_model (gen_server)
  ├── ETS-backed dependency graph
  ├── Persistence: .pixie/world_model.json
  ├── API: build_graph, impact_assessment, get_dependencies, get_dependents
  └── Integration points:
       ├── self_improve → pre-check risk assessment
       ├── openpixie_context → LLM system prompt injection
       ├── openpixie_guardian → post-change graph refresh
       └── openpixie_cron → daily graph rebuild
```

## 3. Dependency Graph

### 3.1 Building the Graph

At boot time, `build_graph/0` scans all loaded `openpixie_*` modules:

1. For each module, extracts the list of other `openpixie_*` modules it calls
2. Uses `xref:m/1` (Erlang cross-reference tool) when available
3. Falls back to source code scanning (regex-based) when `xref` fails
4. Second pass fills in `called_by` (reverse dependencies)

### 3.2 Graph Structure

```json
{
    "openpixie_guardian": {
        "calls": ["openpixie_config", "openpixie_log", "cowboy", "jsx"],
        "called_by": ["openpixie_tools_self_improve", "openpixie_tools_file", "openpixie_tools_command"]
    }
}
```

### 3.3 Persistence

Graph saved to `.pixie/world_model.json`. Restored on restart. Rebuilt daily via cron or after any self-modification.

## 4. Impact Assessment

### 4.1 Before Each Self-Improvement

When `self_improve` is called, the world model:

1. Resolves the target file → module name
2. Looks up the module in the dependency graph
3. Computes: direct dependents, transitive dependents (depth 3)
4. Checks for behavioral contracts at risk
5. Assigns a risk level: **low**, **moderate**, or **high**

### 4.2 Risk Classification

| Condition | Risk Level |
|-----------|------------|
| Safety-critical module + core function modified | **high** |
| Safety-critical module (any change) | **moderate** |
| >5 transitive dependents | **moderate** |
| >3 direct dependents | **moderate** |
| Otherwise | **low** |

### 4.3 Safety-Critical Modules

- `openpixie_guardian` — self-modification safety gate
- `openpixie_permissions` — access control
- `openpixie_auth` — authentication
- `openpixie_sup` — supervisor tree
- `openpixie_circuit_breaker` — resilience

Core functions in these modules (e.g., `pre_check/2`, `check/2`) trigger the highest risk level.

### 4.4 Enforcement

- **High risk**: `self_improve` rejects the change with a message to make a smaller, safer change
- **Moderate risk**: allowed, but the LLM receives dependency context to help make a safer edit
- **Low risk**: allowed normally

## 5. LLM Context Injection

During scheduled mode, the world model injects a dependency summary into the system prompt:

```
## World Model

Dependency graph: 45 modules tracked.
Format: `module` ← modules that call it (dependents)

  `openpixie_guardian` ← openpixie_tools_self_improve, openpixie_tools_file, openpixie_tools_command
  `openpixie_permissions` ← openpixie_ws, openpixie_tools_self_improve
  ...

Use this to understand what depends on the code you are modifying.
Before making changes, check which modules depend on your target.
```

This gives the LLM structural knowledge it cannot derive from reading individual files.

## 6. Post-Change Refresh

After every Guardian post-check (any self-modification tool), the world model graph is rebuilt. This ensures the dependency data stays current with the latest code changes.

## 7. API Reference

| Function | Description |
|----------|-------------|
| `build_graph/0` | Rebuild the full dependency graph |
| `impact_assessment/2` | Get risk assessment for a module + functions |
| `get_dependencies/1` | Get modules that a module calls |
| `get_dependents/1` | Get modules that call a module |
| `get_graph_summary/0` | Module count + list of all tracked modules |
| `get_world_model_context/1` | Formatted context for LLM injection |
| `refresh/0` | Alias for `build_graph/0` |
| `status/0` | Module count + last build timestamp |

## 8. Future Improvements

- **Function-level granularity** — track individual function calls, not just module-level
- **Dialyzer integration** — extract `-spec` annotations as behavioral contracts
- **Contract verification** — after a change, verify that called functions still satisfy their specs
- **Change simulation** — compile in isolation before applying, test behavioral invariants
- **Semantic risk** — use LLM to assess semantic impact beyond structural analysis
- **Historical tracking** — track how the graph changes over time, detect drift

---

*Last updated: 2026-05-20 by manual creation. Guardian should update this document when self-improvement changes the world model system.*
