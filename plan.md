# Branch-Thinking MCP: Go Rewrite Plan

## Overview

Rewrite branch-thinking-mcp from TypeScript to Go for smaller Docker images (~50MB vs ~500MB+), faster startup, single static binary, and trivial cross-compilation.

- **Upstream fork:** https://github.com/MekayelAnik/branch-thinking-mcp (MIT license)
- **Current:** 4 TypeScript files (~90KB), Node.js + npm + supergateway
- **Target:** Single Go binary, optional ONNX Runtime for embeddings

---

## 1. Project Structure

```
branch-thinking-mcp-go/
├── go.mod
├── go.sum
├── main.go                        # Entry point, MCP server setup
├── internal/
│   ├── types/
│   │   └── types.go               # All struct definitions (from types.ts)
│   ├── manager/
│   │   ├── manager.go             # BranchManager core (CRUD, metrics, merge)
│   │   ├── embeddings.go          # Embedding pipeline, caching, cosine similarity
│   │   ├── crossrefs.go           # Cross-reference computation, multi-hop
│   │   ├── tasks.go               # Task extraction, persistence, query, assignment
│   │   ├── visualization.go       # Graph visualization, clustering, centrality
│   │   ├── snippets.go            # Code snippet management
│   │   ├── insights.go            # Insight generation
│   │   ├── summarization.go       # Branch/thought summarization
│   │   └── cache.go               # LRU cache wrappers, stats
│   ├── server/
│   │   ├── server.go              # BranchingThoughtServer, command dispatch
│   │   ├── tools.go               # MCP tool schema definition
│   │   └── session.go             # Session state machine
│   └── autoexec/
│       └── autoexec.go            # AutoExecutionPolicy, safety validator
├── pkg/
│   └── mathutil/
│       └── cosine.go              # Cosine similarity, vector math
├── persistence/
│   └── json.go                    # JSON file read/write (tasks, embeddings cache)
└── Dockerfile                     # Multi-stage Go build
```

---

## 2. Phases

### Phase 1: Foundation
- Go module setup
- All struct definitions in `internal/types/types.go`
- `autoexec.go` port (~80 lines)
- `pkg/mathutil/cosine.go`
- `persistence/json.go` (JSON file I/O, atomic writes)

### Phase 2: Core BranchManager
- Branch CRUD, thought addition, ID generation, metrics, merge
- Insight generation
- Snippet add/search
- Task extraction (regex), CRUD, query, assign, advance
- LRU cache wrappers (`hashicorp/golang-lru/v2`)
- Unit tests

### Phase 3: Embeddings and Semantic Features
- Embedding pipeline (ONNX Runtime or fallback)
- Persistent embedding cache (JSON, backwards compatible)
- Semantic search
- Cross-reference computation (pairwise similarity, multi-hop)
- Thought linking

### Phase 4: Graph Analysis and Visualization
- Graph construction using `gonum.org/v1/gonum/graph`
- K-means clustering (`github.com/muesli/kmeans`)
- Closeness centrality
- Visualization data generation

### Phase 5: MCP Server Integration
- Session state machine
- Tool schema definition (mcp-go format)
- Full command dispatch (20+ commands)
- stdio transport via `github.com/mark3labs/mcp-go`
- **Option:** Use mcp-go's built-in SSE/StreamableHTTP transport to eliminate supergateway entirely

### Phase 6: Docker Integration and Testing
- New Dockerfile (multi-stage Go build)
- Integration tests
- Backwards compatibility with existing JSON data files
- Performance benchmarks vs Node.js

---

## 3. Type Mappings (TS → Go)

```go
// Key mappings (full definitions in internal/types/types.go)

type BranchState string    // "active" | "suspended" | "completed" | "dead_end"
type InsightType string    // "behavioral_pattern" | "feature_integration" | "observation" | "connection"
type CrossRefType string   // "complementary" | "contradictory" | "builds_upon" | "alternative"
type ThoughtLinkType string // "supports" | "contradicts" | "related" | "expands" | "refines"

type ThoughtData struct {
    ID, Content, BranchID string
    Timestamp             time.Time
    Metadata              ThoughtMetadata
    LinkedThoughts        []ThoughtLink
    Score                 *float64
}

type ThoughtBranch struct {
    ID, ParentBranchID string
    State              BranchState
    Priority, Confidence float64
    Thoughts           []ThoughtData
    Insights           []Insight
    CrossRefs          []CrossReference
}

type TaskItem struct {
    ID, Content, BranchID, ThoughtID string
    Status                           string  // "open" | "in_progress" | "closed"
    Assignee, Due                    string
    Priority                         *int
    AuditTrail                       []AuditEntry
}
```

All structs use `json:"camelCase"` tags matching the TS output format for backwards compatibility.

---

## 4. MCP Tool Mapping

| Command | Go Method | Notes |
|---|---|---|
| `create-branch` | `CreateBranch(id, parentID)` | |
| `add-thought` | `AddThought(input)` | Single + batch |
| `focus` | `SetActiveBranch(id)` | |
| `list` | `GetAllBranches()` | |
| `history` | `GetBranchHistory(id)` | LRU cached |
| `insights` | `GetCachedInsights(id)` | LRU cached |
| `crossrefs` | Direct field access | |
| `hub-thoughts` | Sort by crossRef count + score | |
| `semantic-search` | `SemanticSearch(query, topN)` | Needs embeddings |
| `link-thoughts` | `LinkThoughts(from, to, type, reason)` | |
| `add-snippet` | `AddSnippet(content, tags, author)` | |
| `snippet-search` | `SearchSnippets(query, topN)` | |
| `summarize-branch` | `SummarizeBranch(id)` | |
| `doc-thought` | `SummarizeThought(id)` | |
| `extract-tasks` | `ExtractTasks(branchID)` | Regex-based |
| `review-branch` | `ReviewBranch(id)` | Pattern matching |
| `visualize` | `VisualizeBranch(options)` | Graph + clustering |
| `ask` | `AskQuestion(question)` | Placeholder |
| `summarize-tasks` | `SummarizeTasks(branchID)` | Stats aggregation |
| `advance-task` | `AdvanceTask(taskID, status)` | Persistent |
| `assign-task` | `AssignTask(taskID, assignee)` | Persistent |
| `reset-session` | Session state reset | |
| `clear-cache` | `ClearCache()` | |
| `get-cache-stats` | `GetCacheStats()` | |

---

## 5. Embedding Strategy

### Option A: ONNX Runtime (Recommended)
- **Package:** `github.com/yalue/onnxruntime_go`
- **Model:** `all-MiniLM-L6-v2` (same as TS version, ~23MB ONNX file)
- **Pros:** Feature parity, offline, deterministic, backwards-compatible embeddings
- **Cons:** Requires `libonnxruntime.so` (~50MB), tokenizer complexity
- **Docker:** Download model at build time, add ONNX Runtime shared library

### Option B: External API (Simplest)
- Use `POST /v1/embeddings` to local Ollama or OpenAI
- **Pros:** Simplest code, flexible model choice
- **Cons:** External dependency, latency

### Option C: Pure Go TF-IDF (Lightest)
- Bag-of-words with `gonum` matrix operations
- **Pros:** Zero dependencies, fast, tiny binary
- **Cons:** Lower quality, not backwards-compatible

**Recommendation:** Option A for production. Option C as fallback when ONNX is unavailable.

---

## 6. Graph Analysis

Replace `@dagrejs/graphlib` with `gonum.org/v1/gonum/graph`:

| TS (graphlib) | Go (gonum) |
|---|---|
| `new Graph({directed: true})` | `simple.NewDirectedGraph()` |
| `g.setNode(id)` | `g.AddNode(node)` (int64 IDs, use string↔int64 map) |
| `g.setEdge(from, to)` | `g.SetEdge(g.NewEdge(from, to))` |
| `alg.dijkstra(g, node)` | `path.DijkstraFrom(node, g)` |
| `alg.findCycles(g)` | `topo.DirectedCyclesIn(g)` |

K-means: `github.com/muesli/kmeans` or pure Go Lloyd's algorithm (~60 lines).

---

## 7. Persistence

Two JSON files (same format as TS for backwards compatibility):
- `.tasks.json` — `{"tasks": [TaskItem, ...]}`
- `embeddings-cache.json` — `{"<hash>": {"embedding": [...], "hash": "..."}}`

Use atomic writes (write to temp file, `os.Rename`) to prevent corruption.

Hash function compatibility (port TS djb2-variant exactly):
```go
func HashContent(content string) string {
    var hash int32 = 0
    for _, ch := range content {
        hash = ((hash << 5) - hash) + int32(ch)
    }
    return strconv.Itoa(int(hash))
}
```

---

## 8. Docker Integration

### With supergateway (minimal change):
```dockerfile
FROM golang:1.23-bookworm AS builder
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -o /build/branch-thinking ./main.go

FROM debian:bookworm-slim
# ... haproxy, gosu, onnxruntime ...
COPY --from=builder /build/branch-thinking /app/branch-thinking
```

Entrypoint changes: 2 lines — replace `node` command with Go binary path.

### Without supergateway (eliminate Node.js entirely):
Use mcp-go's built-in SSE/StreamableHTTP transport:
```go
server.ServeStreamableHTTP(s, ":38011", "/mcp")
```
Image drops from ~500MB to ~50MB.

---

## 9. Go Package Dependencies

| Purpose | Package | Replaces (TS) |
|---|---|---|
| MCP server | `github.com/mark3labs/mcp-go` | `@modelcontextprotocol/sdk` |
| LRU cache | `github.com/hashicorp/golang-lru/v2` | `lru-cache` |
| Graph analysis | `gonum.org/v1/gonum/graph` | `@dagrejs/graphlib` |
| K-means | `github.com/muesli/kmeans` | `ml-kmeans` |
| ONNX inference | `github.com/yalue/onnxruntime_go` | `@xenova/transformers` |
| JSON | `encoding/json` (stdlib) | `fs-extra` |
| Console colors | `github.com/fatih/color` | `chalk` |
| Lodash utils | `slices`, `maps` (stdlib) | `lodash` |

---

## 10. Testing Strategy

- **Unit tests:** Per package — serialization round-trips, CRUD operations, cache behavior, regex extraction
- **Integration tests:** Full MCP tool call round-trips via JSON-RPC
- **Backwards compatibility:** Load TS-generated `tasks.json` and `embeddings-cache.json` in Go
- **Golden file tests:** Capture TS responses, replay against Go, diff outputs
- **Benchmarks:** Embedding throughput, semantic search over 1000+ thoughts, visualization clustering

---

## 11. Migration Path

1. **JSON compatibility:** All Go structs use identical `json:"camelCase"` tags — existing data files work without migration
2. **MCP protocol:** Same tool name (`branch-thinking`), same input schema, same response format
3. **Docker env vars:** Unchanged (`PORT`, `API_KEY`, `PROTOCOL`, `PUID`, `PGID`)
4. **Rollback:** Keep TS source in repo, parameterize Dockerfile with build arg during transition
