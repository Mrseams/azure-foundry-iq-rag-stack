# Azure Foundry IQ RAG stack

A tested setup for adding grounded AI answers to a business application on Azure. Documents are stored in Azure Blob and indexed with OCR and embeddings in Azure AI Search. **Foundry IQ** (agentic retrieval) searches them, and an Azure OpenAI model writes the answers, with citations, per-user access control, and the application's own data injected into each question.

The design comes from a case-management application in production: legal case files plus a shared library of laws and policies, in French and English. It works for any app where records own documents and users ask questions about a record or about the shared library.

| Path | What it is |
|---|---|
| [`templates/`](templates) | The six Azure AI Search object definitions, with `{{PLACEHOLDERS}}` for names and keys |
| [`provision.sh`](provision.sh) | Fills the placeholders and creates or updates the objects. Safe to re-run; also takes `--fresh` and `--dry-run` |
| [`.env.example`](.env.example) | Every setting, explained |

---

## 1. Architecture

```
App (upload / replace / delete a document)
  │  writes documents/{file}                                  ┌──────────────────────────────┐
  ▼                                                           │  Azure OpenAI (Foundry)      │
Azure Blob container                                          │   chat model: gpt-5          │
  documents/{file}            ← every app file                │   embeddings: 3-large        │
  ai/{document_id}/{file}     ← AI copy + metadata ───┐       └──────────▲──────────▲────────┘
                                                      │ indexer (PT5M,     │          │
                                                      │ or run on demand)  │ embed    │ query planning
                                                      ▼                    │          │
Azure AI Search                                                            │          │
  data source → skillset (OCR → merge → split → embed) → index ────────────┘          │
  knowledge source (searchIndex) → knowledge base (Foundry IQ) ───────────────────────┘
        ▲
        │ retrieve (filter: library + one record + documents the user may open)
App backend ── excerpts + record facts + chat history ──► one chat completion ──► answer with [1], [2] + sources
```

There are two flows:

1. **Indexing, asynchronous.** A queued job copies each document to `ai/{id}/{file}` with metadata, then triggers the indexer. The indexer extracts the text, runs OCR on images, splits the text into chunks, embeds them, and writes one index entry per chunk carrying the metadata.
2. **Answering, synchronous.** The backend calls the knowledge base `retrieve` endpoint with a filter. Foundry IQ plans the searches from the conversation and returns excerpts with their document references. Then **one chat completion** writes the answer from those excerpts plus the app's own data (the record's facts).

Foundry IQ's built-in answer synthesis (`outputMode: answerSynthesis`) isn't used. It grounds only on the retrieved documents, so it ignores the facts you inject and answers "No relevant content was found" to questions those facts answer. Use `extractiveData` and write the answer with your own completion.

---

## 2. Azure resources

One resource group per environment (dev, prod).

| # | Resource | Tier / settings |
|---|---|---|
| 1 | **Storage account** (StorageV2) | Standard LRS is enough. One private container for the app's files. |
| 2 | **Azure AI Search** | **Basic or higher**: Free has no shared private links, no managed identity, and too little storage. Semantic ranker **on** (Free plan or Standard plan); agentic retrieval needs it. |
| 3 | **Azure AI Foundry / Azure OpenAI** (kind `AIServices`) | Two model deployments, below. It is also the billing resource for the OCR skill, so **put it in the same region as the Search service**. |

**Model deployments** on resource 3:

| Deployment | Model | Used for | Notes |
|---|---|---|---|
| `gpt-5` | gpt-5 (or gpt-4.1, gpt-4o) | Foundry IQ query planning, and the app's answers | Reasoning model: no `temperature`; use `max_completion_tokens` and `reasoning_effort` |
| `text-embedding-3-large` | text-embedding-3-large | Embeddings at indexing time and at query time | 3072 dimensions. Changing the model means rebuilding the index; see §9 |

Give both deployments enough TPM quota. A bulk backfill (re-indexing everything) is the peak load on the embedding deployment.

### 2.1 Networking and identity

Inside Azure, Search reaches Blob and OpenAI over **shared private links**:

| On the Search service | Target | Sub-resource (group ID) | Why |
|---|---|---|---|
| Shared private access | Storage account | `blob` | The indexer reads the documents |
| Shared private access | Foundry resource | `openai_account` | The embedding skill, the vectorizer, and the knowledge base model |
| Shared private access | Foundry resource (same one, second link) | `cognitiveservices_account` | Search checks the OCR billing resource through it |

- Each link must be **approved on the target resource**: Networking, Private endpoint connections, Approve.
- The indexer must run with `executionEnvironment: "private"` to use these links. It's already set in [`4-indexer.json`](templates/4-indexer.json).
- Search **system-assigned managed identity**: turn it on. To read Blob without the account key, grant it **Storage Blob Data Reader** on the storage account, and set `AZURE_STORAGE_RESOURCE_ID`.
- Search **API key authentication** must stay enabled ("API keys" or "Both"). The app calls Search with the admin key.

**Behind a corporate API gateway.** Some networks can't reach `*.blob.core.windows.net`, `*.search.windows.net` or `*.openai.azure.com` directly, so the app goes through a gateway (`https://gateway.example.com/<project>/<resource>`). If the gateway strips a path prefix, Shared Key signatures on Blob break, because they sign the request path. Sign a container **SAS** locally with the account key and send Blob requests to the gateway URL with that SAS. Search and OpenAI use an `api-key` header, which a gateway passes through unchanged. Search itself never goes through the gateway: it uses the resources' own URLs from inside Azure.

---

## 3. Search objects (Foundry IQ)

[`provision.sh`](provision.sh) sends the six templates with `PUT`, in this order. `<APP>` is your prefix:

| Template | REST collection | Name | Role |
|---|---|---|---|
| [`1-datasource.json`](templates/1-datasource.json) | `datasources` | `<APP>-documents-ds` | The Blob container, limited to the `ai/` prefix |
| [`2-index.json`](templates/2-index.json) | `indexes` | `<APP>-documents` | One entry per chunk: metadata, text, vector, semantic configuration |
| [`3-skillset.json`](templates/3-skillset.json) | `skillsets` | `<APP>-documents-skillset` | OCR → merge → split → embed, then projection of chunks into the index |
| [`4-indexer.json`](templates/4-indexer.json) | `indexers` | `<APP>-documents-indexer` | Runs the pipeline every 5 min, and on demand |
| [`5-knowledge-source.json`](templates/5-knowledge-source.json) | `knowledgesources` | `<APP>-documents-ks` | Exposes the index to Foundry IQ |
| [`6-knowledge-base.json`](templates/6-knowledge-base.json) | `knowledgebases` | `<APP>-kb` | The agentic retrieval endpoint, with its planning model |

They target **api-version `2025-11-01-preview`**.

**What matters in each:**

- **Data source.**
  - **Credentials.** The indexer reads Blob with `ResourceId=…;`, which uses the Search managed identity, or with an account-key connection string. The script picks one depending on whether `AZURE_STORAGE_RESOURCE_ID` is set.
  - **No deletion detection policy.** It isn't needed, because the app deletes chunks itself (§6.2).
- **Index.**
  - **Filter keys.** `document_id`, `case_id` and `scope` are filterable strings, since blob metadata is text.
    - `scope` is `library` (shared reference documents) or `case` (documents of one record).
    - Rename `case_id` to whatever your records are (`project_id`, `client_id`…); it is only a convention between the app and the index.
  - **Vector and semantic search.** The vectorizer lets the knowledge base embed queries itself, and the semantic configuration is required by Foundry IQ.
- **Skillset.**
  - **OCR billing.** `cognitiveServices` (`AIServicesByKey`, the resource's `https://<name>.cognitiveservices.azure.com` endpoint) attaches the billing resource for OCR. **Without it, Azure enriches only 20 documents a day**, and past that the indexer stops for *every* document, not just the scanned ones.
  - **Chunk size.** 2000-character chunks with 200 characters of overlap work well for legal texts.
  - **Metadata.** The index projection copies each blob's metadata onto every chunk.
- **Indexer.**
  - **Failures.** `maxFailedItems: -1` means one bad file never blocks the others. Track failures per document from the run history instead (§6.3).
  - **Images.** `imageAction: generateNormalizedImages` feeds the OCR skill. Azure charges image extraction separately.
- **Knowledge source.** `sourceDataFields` are returned with each reference, so the app knows which document an excerpt comes from.
- **Knowledge base.**
  - **Mode.** `outputMode: extractiveData`, so the app writes the answer.
  - **Retrieval instructions** (`RETRIEVAL_INSTRUCTIONS`) are the main lever on retrieval quality: describe your corpus, its languages, and how questions are asked.

---

## 4. Configuration

All settings are in [`.env.example`](.env.example). The same names suit the application's own configuration.

| Variable | Notes |
|---|---|
| `APP` | Prefix of the Search object names |
| `AZURE_STORAGE_CONNECTION_STRING` | Account key connection string. The app uses it, and so does the indexer unless `AZURE_STORAGE_RESOURCE_ID` is set |
| `AZURE_STORAGE_CONTAINER` | The app's documents container |
| `AZURE_STORAGE_RESOURCE_ID` | When set, the indexer reads Blob with the Search managed identity |
| `AZURE_STORAGE_GATEWAY_URL` | Only behind a gateway (§2.1) |
| `AZURE_SEARCH_ENDPOINT`, `AZURE_SEARCH_KEY` | Search **admin** key: it creates objects and deletes chunks. Backend only |
| `AZURE_OPENAI_ENDPOINT` | What the **app** calls; it can be a gateway URL |
| `AZURE_OPENAI_RESOURCE_URL` | What **Search** calls from inside Azure: always `https://<name>.openai.azure.com` |
| `AZURE_OPENAI_KEY` | Foundry resource key |
| `AZURE_OPENAI_CHAT_DEPLOYMENT`, `AZURE_OPENAI_EMBEDDING_DEPLOYMENT` | Deployment names |
| `AZURE_AI_SERVICES_URL`, `AZURE_AI_SERVICES_KEY` | OCR billing; the key defaults to `AZURE_OPENAI_KEY` (same resource) |
| `RETRIEVAL_INSTRUCTIONS` | How Foundry IQ should search your corpus |

Each endpoint has two URLs: one the app uses, possibly through a gateway, and one Search uses from inside Azure. Mixing them up is the most common cause of a failed provisioning or indexer run.

**API versions:**
- Azure AI Search (objects, `retrieve`, docs): `2025-11-01-preview`.
- Azure OpenAI chat completions: `2025-04-01-preview`.

---

## 5. Provisioning

```sh
cp .env.example .env              # then fill it in
./provision.sh --dry-run          # check the filled JSON, without calling Azure
./provision.sh                    # create or update the 6 objects
./provision.sh --fresh            # delete them first: needed when an index field or the vector size changes
```

Requires bash and curl. Values are JSON-escaped when the placeholders are filled. Run it on every deploy: it picks up template changes and leaves everything else as it was.

---

## 6. The app's side of the contract

### 6.1 Sync a document (queued job)

1. Delete the previous AI copy and its chunks (§6.2).
2. Copy `documents/{file}` to `ai/{document_id}/{file}`, keeping the content type.
3. Set the blob metadata:
   - `document_id`;
   - `case_id`, empty for the library;
   - `scope`, `library` or `case`;
   - `title`, **in ASCII only**: metadata travels as HTTP headers, so transliterate accents.
4. `POST indexers('<APP>-documents-indexer')/run`; treat a `409` (already running) as success.

Trigger it from the document model's events (created, file replaced, deleted) rather than from each controller, so every upload path is covered. In the job, set 3 tries with a backoff (30 s, then 120 s), and dispatch it after the database transaction commits.

### 6.2 Delete a document

Delete the `ai/{id}/` blobs, **then delete the chunks directly**: search with `filter: document_id eq '{id}'`, select `chunk_id`, then `POST indexes('…')/docs/index` with `@search.action: delete`. This doesn't depend on blob soft delete.

An indexer run that had already started may write the chunks again after that delete, so queue a second cleanup about 10 minutes later.

### 6.3 Indexing status per document

Store a status on each document: `queued`, `indexing`, `indexed`, `no_text` or `failed`. A scheduled task (every minute) settles the documents in `indexing`:

- `indexed`: the document has chunks; count them with `docs/search`, `count: true`, `top: 0`, filtered on the `document_id`.
- `no_text`: a successful indexer run that started after the copy produced no chunks, for example an image with no readable text.
- `failed`: the indexer's `status` endpoint (`executionHistory[].errors`) names the blob.

### 6.4 Retrieve

```http
POST {AZURE_SEARCH_ENDPOINT}/knowledgebases('<APP>-kb')/retrieve?api-version=2025-11-01-preview
api-key: <search key>

{
  "messages": [
    { "role": "user", "content": [{ "type": "text", "text": "Case context (...):\n<facts>\n\nQuestion: <question>" }] }
  ],
  "knowledgeSourceParams": [{
    "kind": "searchIndex",
    "knowledgeSourceName": "<APP>-documents-ks",
    "filterAddOn": "(scope eq 'library' or case_id eq '21') and search.in(document_id, '12,15,74', ',')",
    "includeReferences": true,
    "includeReferenceSourceData": true,
    "rerankerThreshold": 0
  }],
  "outputMode": "extractiveData",
  "retrievalReasoningEffort": { "kind": "medium" }
}
```

- **History.** Send up to the last 10 chat messages, oldest first, with roles `user` and `assistant`. Foundry IQ plans its searches from the whole conversation.
- **Your own data.** Inject your record's facts into the **last** user message, so the searches target them.
- **`filterAddOn`** does the scoping:
  - library only, or library plus one record;
  - **per-user access**: add `search.in(document_id, …)` with the IDs the user may open, computed on each request, so access changes apply immediately without re-indexing.
- **`rerankerThreshold: 0`** keeps the weaker matches. The default threshold often drops the record's own documents.
- **`retrievalReasoningEffort: medium`** runs a second planning round when the first results fall short. It is slower, about 10–30 s.
- **The response** has two parts:
  - `response[0].content[].text`: a JSON list of excerpts `[{ref_id, title, content}]`;
  - `references[]`: maps each `id` to its `sourceData`, the `document_id` and `title`.

### 6.5 Answer (one completion)

```http
POST {AZURE_OPENAI_ENDPOINT}/openai/deployments/gpt-5/chat/completions?api-version=2025-04-01-preview
api-key: <openai key>

{
  "messages": [
    { "role": "system", "content": "<instructions>\n\nCASE DATA\n<facts>\n\nDOCUMENT EXCERPTS\n<excerpts JSON>" },
    ...chat history...
  ],
  "max_completion_tokens": 16000,
  "reasoning_effort": "low"
}
```

- **Instructions that worked:**
  - use only the record data and the excerpts;
  - cite each excerpt as exactly `[ref_id:N]`;
  - state facts from your own data **without** a citation;
  - answer in the language of the user's last message;
  - keep it concise; markdown, no tables.
- **Expect the model to break the citation format sometimes**, for example `[3:ARTICLE 9]` or `[ref_id:3; ref_id:7]`. Parse it tolerantly, then renumber the citations `[1]`, `[2]`… with one number per document.
- **Return the sources as data**, `[{number, document_id, title}]`, and let the UI build the preview links from the document's *current* file name.
- **Rendering HTML.** Convert the markdown with raw HTML **stripped**. Many chat UIs insert messages as HTML, and model output must not inject markup.
- **Structured output.** For a JSON result, such as a record overview with a prediction and confidence, add `response_format: {type: json_schema, strict: true, schema}`.
- **Empty answers.** An empty `content` with `finish_reason: length` means the reasoning used up the tokens. Raise `max_completion_tokens`.

---

## 7. First setup, step by step

1. **Create the resources** (§2): the storage account and container, Search (Basic or higher, semantic ranker on, managed identity on), and the Foundry resource with its two deployments, in the Search region.
2. **Networking.** Create the three shared private links on Search (`blob`, `openai_account`, `cognitiveservices_account`) and approve each on its target. Grant the Search managed identity **Storage Blob Data Reader** on the storage account.
3. **Gateway routes**, if you use a corporate gateway. Route Blob, Search and Foundry through it.
4. **Configuration**: fill in `.env`.
5. **Provision**: `./provision.sh`. Check the six objects in the portal: Search service, then Agentic retrieval, and Indexes or Indexers.
6. **Move existing files to Blob**, if the app stored them elsewhere before. Copy them once while the app still uses the old storage, switch the app to Blob, then copy again to catch the files uploaded in between, skipping those already there.
7. **Backfill the index**: queue the sync job for every existing document, then follow the statuses.

**Every deploy:**
- the app's own build and migrations;
- `./provision.sh`;
- restart the queue workers so they load the new code.

The queue worker and the scheduler (for the status refresh) run continuously, outside the deploy pipeline.

**Web server timeout.** An answer takes 15–40 s. The web server must allow about 60 s on the route that waits for it, and the app's own request time limit must be raised on that route.

---

## 8. Verification checklist

- [ ] `./provision.sh` succeeds twice in a row.
- [ ] Upload a PDF to the library and one to a record. The `ai/{id}/` blobs appear with the right metadata, and after an indexer run the index has chunks with `scope=library`, and `scope=case` with the right `case_id`.
- [ ] Upload a scanned PDF. Its OCR text is indexed: the document has chunks and isn't `no_text`.
- [ ] Delete a file. Its chunks are gone right away.
- [ ] **Isolation.** A library-only retrieval returns only `scope=library`. Record A's retrieval never returns record B's documents; test with a distinctive phrase uploaded to B.
- [ ] **Access.** A user without access to a restricted document never gets its excerpts.
- [ ] **Facts.** A question that only your injected facts answer (an amount, a court) is answered without a citation.
- [ ] **Language.** A question in another language is answered in that language.
- [ ] **Sources.** Each source link opens the right document.
- [ ] **Switch off.** With the AI disabled, the UI shows a clean "not available" message.

---

## 9. Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| "No relevant content was found" when the answer is in your injected facts | `answerSynthesis` grounds only on documents | `extractiveData`, plus your own completion |
| The record's own documents never come back | The default reranker threshold drops weaker matches | `rerankerThreshold: 0` |
| The indexer stops for every document after about 20 a day | No billing resource for the skillset (OCR) | Set `cognitiveServices` with `AIServicesByKey` and add the `cognitiveservices_account` private link |
| Skillset save fails on the billing resource | Search can't reach the Foundry resource to check it | Second shared private link, `cognitiveservices_account` |
| The indexer can't read Blob or reach OpenAI | Running in the multi-tenant environment, or a link not approved | `executionEnvironment: private`, and approve each link |
| Blob calls through a gateway fail with 403 signature errors | The gateway strips its path prefix, which breaks Shared Key | Container SAS signed locally |
| Blob metadata upload fails | Non-ASCII characters in a metadata value | Transliterate to ASCII |
| Provisioning fails after changing the embedding model | Vector size and model name are fixed in the index | Change `dimensions`/`modelName` in the index and skillset, then `./provision.sh --fresh` and re-sync every document |
| An empty answer from gpt-5 | Reasoning used up the token budget | Raise `max_completion_tokens`; don't send `temperature` |
| Citations don't render | The model invented another marker format | A strict instruction, plus a tolerant parser |
| Deleted documents still answer | The indexer re-wrote chunks after the delete | A second cleanup about 10 min later |
| A previous AI analysis gets repeated as fact | It was fed back into the generation that produces it | Give it to the chat only, labelled as an earlier analysis, never to its own regeneration |
| Answers hit timeouts | Retrieval at medium effort plus the completion take 15–40 s | A 60 s web-server timeout, the request limit raised on that route, and a "thinking" state in the UI |
| The total count of a search reads as empty | `@odata.count` read with a dotted-path helper | Read the key directly: `json['@odata.count']` |

---

## 10. Costs and security

**Cost drivers:**
- the Search tier: Basic is a fixed monthly cost;
- semantic ranker queries above the free quota;
- embedding tokens: indexing and every query;
- OCR and image extraction, per image;
- the chat model tokens: query planning plus answers.

A full re-index re-pays the embeddings and OCR for every document, so run it only when needed.

**Security:**
- **Keys.** They stay in `.env` and your secret store, never in Git or logs; `.env` is git-ignored here. Move to managed identities where your network allows it.
- **Admin key.** The Search admin key can delete the index, so keep it on the backend only.
- **Retrieval filter.** It is the only access control on documents in AI answers. Compute it on the backend, on every request, from the same rules as your document downloads.
- **Who can use the AI.** Limit the AI endpoints to the users who may see the whole library.
- **Chat privacy.** Keep AI chats private to their owner, and check membership on every message endpoint.
