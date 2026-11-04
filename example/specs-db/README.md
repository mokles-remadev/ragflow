# Local specification DB for Claude

Run RAGFlow on your machine as a searchable database of specification PDFs
(scanned or digital), then give a Claude agent access to it over MCP.

```text
spec PDFs ──ingest.sh──▶ RAGFlow (DeepDoc layout + OCR → chunks → embeddings)
                                   │
Claude Code / Agent SDK ◀──MCP── POST http://localhost:9380/api/v1/mcp
```

RAGFlow's built-in MCP endpoint provides `ragflow_retrieval`,
`ragflow_list_datasets` and `ragflow_list_chats`. You don't need to change the
server or open any extra port.

## Requirements

- Linux x86-64 host with Docker and Docker Compose v2. macOS is not supported by the Go backend yet. On Windows, use WSL2.
- At least 4 CPU cores, 16 GB RAM and 50 GB of free disk.
- `curl` and `jq`.
- An embedding model. Choose one of these:
  - local, no API key: `WITH_TEI=1` (see step 1);
  - a provider such as OpenAI, Voyage, Jina or Ollama, configured in the UI.

## 1. Start RAGFlow

```bash
example/specs-db/start.sh
```

Or, with a local embedding server (English: `BAAI/bge-small-en-v1.5`, about 1.2 GB RAM):

```bash
WITH_TEI=1 example/specs-db/start.sh
```

For multilingual specs, use `TEI_MODEL=BAAI/bge-m3`, which needs about 21 GB RAM.

If port 80 is already taken (Apache, nginx, another container), move the web UI. The script checks for busy ports before it starts anything.

```bash
WEB_PORT=8080 WITH_TEI=1 example/specs-db/start.sh   # UI at http://localhost:8080, HTTPS on 8443
```

The API and MCP endpoint stay on port 9380.

If you can reach other hosts from this machine, first change `ADMIN_DEFAULT_PASSWORD` in `docker/.env`.

## 2. One-time UI setup

1. Open <http://localhost> (or `http://localhost:$WEB_PORT`) and register. The first account you create is yours.
2. Under **Model providers**, set the default **embedding** model. With `WITH_TEI=1`, the local TEI model is already wired in. Retrieval doesn't need a chat LLM.
3. Click your avatar, open **API**, and create a key:

```bash
export RAGFLOW_API_KEY=ragflow-...
```

## 3. Load the specs

```bash
example/specs-db/ingest.sh /path/to/specs
```

- The script creates the dataset `specifications` (`DATASET_NAME=` to change it) with the **manual** chunker. That chunker follows numbered section hierarchies, which suits specs. If your documents have no section structure, use `PARSER_ID=general`.
- It walks the directory recursively and uploads every `*.pdf`. Set `FILE_GLOB='*'` to also include DOCX, images and other files.
- DeepDoc runs in-process. It detects layout, tables and reading order, and it OCRs scanned pages. No extra OCR setup is needed.
- It waits until indexing finishes and lists any failures. Re-running it uploads only new files and retries failed or stopped ones.
- OCR on CPU is slow, roughly a few seconds per page. To speed it up, raise `RAGFLOW_INGESTOR_PAGE_CONCURRENCY` (maximum 16) in `docker/.env` and recreate the container.

Spot-check the OCR quality in the UI (**Dataset → document → chunks**) before
trusting the results. Fix bad chunks there, or re-scan the page at 300 dpi.

## 4. Connect Claude

**Claude Code:**

```bash
example/specs-db/connect-claude.sh
```

This checks the endpoint and runs `claude mcp add --transport http specs …` for your user.

To write a shareable `.mcp.json` instead, run this from your agent's project directory:

```bash
SCOPE=project /path/to/ragflow/example/specs-db/connect-claude.sh
```

The file references `${RAGFLOW_API_KEY}` and does not contain the key itself.

Copy `CLAUDE.md.snippet` into your agent project's `CLAUDE.md`. It tells the
agent when to search the specs, how to cite them, and how to treat OCR noise.

**Claude Agent SDK:**

```python
options = ClaudeAgentOptions(
    mcp_servers={
        "specs": {
            "type": "http",
            "url": "http://localhost:9380/api/v1/mcp",
            "headers": {"Authorization": f"Bearer {os.environ['RAGFLOW_API_KEY']}"},
        }
    },
    allowed_tools=["mcp__specs__ragflow_retrieval", "mcp__specs__ragflow_list_datasets"],
)
```

## Verify

```bash
curl -sS http://localhost:9380/api/v1/mcp \
  -H "Authorization: Bearer $RAGFLOW_API_KEY" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ragflow_retrieval","arguments":{"question":"operating temperature range"}}}'
```

## Notes

- **Agent on another machine:** the API port 9380 is published on all interfaces. Put it behind a firewall or VPN rather than exposing it to the internet.
- **Tuning retrieval:** in `ragflow_retrieval`, set `keyword: true` for exact clause or part numbers. Raise `vector_similarity_weight` (for example to `0.7`) for paraphrased questions.
- **Stopping and data:** `docker compose -f docker/docker-compose.yml down` stops the stack and keeps your data in Docker volumes. Adding `-v` wipes it.
