# IKMacros Bridge

How `figma-to-swiftui` adapts service / DTO output when the target project uses **IKMacros** (`@APIProtocol`, `@JsonSerializable`, etc.). Conditional — applies only when `c1-conventions.json.usesIKMacros == true`.

The skill rarely needs to generate networking code (most Figma-to-SwiftUI tasks are UI-only). When the user's request DOES require new service code (e.g. "wire this list to the /articles endpoint"), this file is the spec.

---

## §1. Detection (C1 audit)

C1 sets `usesIKMacros = true` when ANY of these signals are present:

| Signal | Where |
|---|---|
| `import IKMacros` in any existing Swift file | grep |
| `@APIProtocol(baseURL:` in any file | grep |
| `@JsonSerializable` on a struct | grep |
| `Package.swift` lists `ikmacros` package | manual |
| `IKAPIRepository` protocol conformance | grep |

If any signal present → `usesIKMacros = true`. Skill emits IKMacros-flavored DTOs and services.

If absent → skill emits plain `Codable` DTOs and a hand-written `URLSession` service. Do not introduce IKMacros into a project that doesn't have it.

C1 also captures `apiRepoTypeName` (e.g. `AppAPIRepository`) so the skill knows which repo to inject.

---

## §2. DTO — `@JsonSerializable`

Every DTO the skill generates uses `@JsonSerializable` + `@JsonKey` to map JSON keys to Swift names:

```swift
import IKMacros

@JsonSerializable
struct ArticleDTO: Codable {
    @JsonKey(key: "id") var id: Int = 0
    @JsonKey(key: "title") var title: String = ""
    @JsonKey(key: "author_name") var authorName: String = ""
    @JsonKey(key: "published_at") var publishedAt: String = ""
    @JsonKey(key: "is_featured") var isFeatured: Bool = false

    init(
        id: Int = 0,
        title: String = "",
        authorName: String = "",
        publishedAt: String = "",
        isFeatured: Bool = false
    ) {
        self.id = id
        self.title = title
        self.authorName = authorName
        self.publishedAt = publishedAt
        self.isFeatured = isFeatured
    }
}
```

**Rules:**
- Every property has a default value (so partial JSON decodes to a partially-populated struct without throwing — `@JsonKey(ignoringErrors: true)` is the default).
- The init takes every property with the same default.
- DTOs end in `DTO`. Domain models (the type the View consumes) live in `Entities/` and have no suffix — they map FROM `DTO` via a converter.

**Required vs optional decoding:**
- `@JsonKey(key: "...", ignoringErrors: true)` (default) — missing key keeps the default value, no throw.
- `@JsonKey(key: "...", ignoringErrors: false)` — missing key throws. Use only for fields the API contract guarantees and your code cannot tolerate missing.

---

## §3. Service — `@APIProtocol`

Networking lives in `Core/Network/` (or wherever C1 detected the existing convention). Each service is a `Sendable` protocol with `@APIProtocol`:

```swift
import IKMacros

@APIProtocol(
    baseURL: "https://api.example.com/v2",
    defaultHeaders: defaultAPIHeaders
)
protocol ArticleService: Sendable {

    @GET(path: "articles", fields: [
        "page" => .query,
        "limit" => .query(key: "per_page")
    ])
    func getArticles(page: String, limit: String) async throws -> PaginatedResponse<ArticleDTO>

    @GET(path: "articles/{id}", fields: [
        "id" => .path,
        "auth" => .headers
    ])
    func getArticle(id: String, auth: [String: String]) async throws -> ArticleDTO

    @POST(path: "articles", fields: [
        "data" => .body,
        "auth" => .headers
    ])
    func createArticle(data: CreateArticleRequest, auth: [String: String]) async throws -> ArticleDTO
}
```

The macro generates `ArticleServiceImpl` automatically. Use it as:

```swift
let service: ArticleService = ArticleServiceImpl(repo: AppAPIRepository.shared)
```

**Rules:**
- Protocol is `Sendable` (compile-time required by `@APIProtocol`).
- Every method is `async throws`.
- Path variables in the URL `{id}` map to a `.path` field with the same key.
- Use the `=>` operator form for new code (`"key" => .query`); the explicit enum form (`.query("key", mapToParamName: "key")`) is older syntax kept for backward compat.
- Headers field is `[String: String]`; per-request headers merge with default (per-request wins).
- Body field accepts `Codable` — the macro auto-calls `toDictionary()` to encode.

---

## §4. ViewModel uses the protocol, not the impl

```swift
@MainActor
final class ArticleListViewModel: ObservableObject {
    enum Action { /* ... */ }
    @Published var articles: [Article] = []
    // ...

    private let articleService: ArticleService

    init(articleService: ArticleService = ArticleServiceImpl(repo: AppAPIRepository.shared)) {
        self.articleService = articleService
    }

    private func fetch() async {
        do {
            let response = try await articleService.getArticles(page: "1", limit: "20")
            articles = response.data.map(Article.init(dto:))
        } catch { /* ... */ }
    }
}
```

The default-value form lets tests inject a mock conforming to `ArticleService` without changing call sites:

```swift
struct MockArticleService: ArticleService {
    var stubArticles: [ArticleDTO] = []
    func getArticles(page: String, limit: String) async throws -> PaginatedResponse<ArticleDTO> {
        PaginatedResponse(data: stubArticles, totalCount: stubArticles.count, page: 1)
    }
    // ... other methods stubbed
}
```

(Tests are out of scope for this skill, but the protocol-based design is what makes them possible.)

---

## §5. DTO → Entity mapping

The skill maps DTOs into domain models the View can consume directly:

```swift
// Entities/Article.swift
struct Article: Identifiable, Hashable {
    let id: Int
    let title: String
    let authorName: String
    let publishedAt: Date?
    let isFeatured: Bool

    init(dto: ArticleDTO) {
        self.id = dto.id
        self.title = dto.title
        self.authorName = dto.authorName
        self.publishedAt = ISO8601DateFormatter().date(from: dto.publishedAt)
        self.isFeatured = dto.isFeatured
    }
}
```

Why split DTO and Entity:
- DTO mirrors the API; its shape is dictated by the server.
- Entity is what your UI / business logic should care about — typed `Date`, computed properties, validation.
- Server changes a key from `author_name` to `authorname` → only the DTO and one mapping site change; all UI code is untouched.

If the API and domain shapes are 1:1 identical, the skill is allowed to skip the Entity and let the View consume the DTO directly. But it must say so in the verification summary so the user knows.

---

## §6. When NOT to use IKMacros

Even when the project has IKMacros, skip it for:

- **Models that are not transferred over the network.** A `OnboardingStep` enum or a local pure-data struct doesn't need `@JsonSerializable`.
- **One-off response shapes** that don't deserve a DTO (e.g. a single `String` response). Inline-decode with `JSONDecoder`.
- **Streaming / WebSocket / non-HTTP transports.** IKMacros is HTTP-only.

---

## §7. C8-ikmacro.sh (informational only)

There is no hard gate for IKMacros — the macro itself fails compilation when used wrong, which is enough.

The skill does emit a soft check: when `usesIKMacros == true` AND the run generated a service file, verify:
1. The service protocol conforms to `Sendable`.
2. Every method is `async throws`.
3. Path variables in the URL match `.path` fields.

These mirror the macro's compile-time errors but catch them earlier in the verification summary.

---

## §8. App boot — repository registration

`@APIProtocol` services need an `IKAPIRepository` instance via init. C1 records `apiRepoTypeName` (e.g. `AppAPIRepository`) by reading the App entry / DI container. The skill instantiates services like:

```swift
ArticleServiceImpl(repo: AppAPIRepository.shared)
```

…where `AppAPIRepository.shared` is whatever the project already exposes. The skill does NOT wire up a new singleton or DI graph; it reuses what exists.
