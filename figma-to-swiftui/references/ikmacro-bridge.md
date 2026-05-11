# IKMacros Bridge

How `figma-to-swiftui` adapts repository / DTO output when the target project uses **IKMacros** (`@APIProtocol`, `@JsonSerializable`, etc.). Conditional — applies only when `c1-conventions.json.usesIKMacros == true`.

**Canonical source: `ikame-ios-coding/references/api-ikmacros.md` and `references/ikame-decision-table.md` §3 (D-214, D-215).** This file holds only the figma-specific delta — DTO ↔ Entity mapping when figma drives the data shape, and per-endpoint code generation patterns.

The skill rarely needs to generate networking code (most Figma-to-SwiftUI tasks are UI-only). When the user's request DOES require new endpoint code (e.g. "wire this list to the /articles endpoint"), this file is the spec.

---

## §1. Detection (C1 audit)

C1 sets `usesIKMacros = true` when ANY of these signals are present:

| Signal | Where |
|---|---|
| `import IKMacros` in any existing Swift file | grep |
| `@APIProtocol(baseURL:` in any file | grep |
| `@JsonSerializable` on a struct | grep |
| `Podfile` lists `pod 'IKMacros'` (or umbrella `pod 'IKCoreApp'` re-export) | grep |
| `IKAPIRepository` protocol conformance | grep |
| `enum API { static var ... }` registry file (typically `Core/Network/API.swift`) | grep |

If any signal present → `usesIKMacros = true`. Skill emits IKMacros-flavored DTOs and repositories.

If absent → skill emits plain `Codable` DTOs and a hand-written `URLSession` client. Do not introduce IKMacros into a project that doesn't have it.

C1 also captures `apiRegistry`:
- `registryEnumName` (e.g. `API`) — the registry enum the skill must extend.
- `registryFilePath` (e.g. `Core/Network/API.swift`) — where to add the new accessor.
- `sharedRepoExpr` (e.g. `sharedRepo`, `AppAPIRepository.shared`) — the expression the registry uses to instantiate each `<Domain>RepositoryImpl(repo:)`.

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

## §3. Repository — `@APIProtocol`

Networking lives in `Core/Network/Repositories/` (canonical) or wherever C1 detected the existing convention. Each repository is a `Sendable` protocol with `@APIProtocol`:

```swift
import IKMacros

@APIProtocol(
    baseURL: AppConstants.baseURL,
    defaultHeaders: [
        "Accept": "application/json",
        "X-Platform": "iOS"
    ]
)
protocol ArticleRepository: Sendable {

    @GET(path: "articles", fields: [
        "page"  => .query,
        "limit" => .query(key: "per_page")
    ])
    func getArticles(page: Int, limit: Int) async throws -> PaginatedResponse<ArticleDTO>

    @GET(path: "articles/{id}", fields: [
        "id"   => .path,
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

The macro generates `ArticleRepositoryImpl` automatically. **Never instantiate `ArticleRepositoryImpl(...)` at call sites** — go through the registry (§3a).

**Rules:**
- Naming: `<Domain>Repository`. Macro generates `<Domain>RepositoryImpl`. The figma-to-swiftui skill canonical name is "Repository", not "Service" — matches `ikame-ios-coding/references/api-ikmacros.md`.
- Protocol is `Sendable` (compile-time required by `@APIProtocol`).
- Every method is `async throws`.
- Return type must be `Decodable` (or `Sendable` for raw types).
- Path variables in the URL `{id}` map to a `.path` field with the same parameter name.
- Use the `=>` operator form (`"key" => .query`); the explicit enum form (`.query("key", mapToParamName: "key")`) is older syntax kept for backward compat.
- Headers field is `[String: String]`; per-request headers merge with default (per-request wins).
- Body field accepts `Encodable`.

---

## §3a. Expose via `enum API` registry — non-negotiable

Every repository goes through a single `enum API` registry. **No `<Domain>RepositoryImpl(...)` instantiation outside it.**

```swift
// Core/Network/API.swift
import IKCoreApp

enum API {

    static var articleRepository: any ArticleRepository {
        ArticleRepositoryImpl(repo: sharedRepo)
    }

    static var userRepository: any UserRepository {
        UserRepositoryImpl(repo: sharedRepo)
    }

    // Shared IKAPIRepository — resolved from app DI / created once.
    private static let sharedRepo: IKAPIRepository = ...
}
```

**Skill action when adding a new repository:**

1. Define the protocol with `@APIProtocol(...)` per §3.
2. Add `static var <domain>Repository: any <Domain>Repository { <Domain>RepositoryImpl(repo: sharedRepo) }` to `enum API` (use the actual `sharedRepoExpr` captured by C1).
3. Use as `API.<domain>Repository.<method>(...)` from ViewModels.

The registry is **one place** to swap base URL, change shared `IKAPIRepository`, or hook in interceptors. ViewModels never reference `Impl` types — only protocols.

---

## §4. ViewModel injection via `API.<domain>Repository` default

```swift
@MainActor
final class ArticleListViewModel: ObservableObject {
    enum Action { /* ... */ }
    enum Route: Equatable, Hashable { /* ... */ }

    @Published var articles: [Article] = []
    @Published var isLoading: Bool = false
    @Published var route: Route?

    private let articleRepository: any ArticleRepository

    init(articleRepository: any ArticleRepository = API.articleRepository) {
        self.articleRepository = articleRepository
    }

    private func fetch() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await articleRepository.getArticles(page: 1, limit: 20)
            articles = response.data.map(Article.init(dto:))
        } catch {
            IKToast.show(.error, message: error.localizedDescription)
        }
    }
}
```

`init(<name>Repository: any <Name>Repository = API.<name>Repository)` is the **canonical** form — tests pass a mock; production uses the registry default. **Banned**: `init(<name>Repository: ... = <Name>RepositoryImpl(repo: AppAPIRepository.shared))` (direct Impl instantiation) — always go through `API.<name>Repository`.

Tests inject a mock conforming to the same protocol:

```swift
struct MockArticleRepository: ArticleRepository {
    var stubArticles: [ArticleDTO] = []
    func getArticles(page: Int, limit: Int) async throws -> PaginatedResponse<ArticleDTO> {
        PaginatedResponse(data: stubArticles, totalCount: stubArticles.count, page: 1)
    }
    // ... other methods stubbed
}

let sut = ArticleListViewModel(articleRepository: MockArticleRepository(stubArticles: [.fixture()]))
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

The skill does emit a soft check: when `usesIKMacros == true` AND the run generated a repository file, verify:
1. The repository protocol conforms to `Sendable`.
2. Every method is `async throws`.
3. Path variables in the URL match `.path` fields with the same Swift parameter name.
4. The new repository was exposed through `enum API` (registry file at `c1-conventions.json.apiRegistry.registryFilePath`).
5. No ViewModel imports `<Domain>RepositoryImpl` directly — every call site uses `API.<domain>Repository`.

These mirror the macro's compile-time errors but catch them earlier in the verification summary.

---

## §8. App boot — registry singleton

`@APIProtocol` repositories need an `IKAPIRepository` instance via init. The `enum API` registry holds a single `private static let sharedRepo: IKAPIRepository = ...` (resolved from the app's DI / created once at app start). C1 captures `apiRegistry.sharedRepoExpr` (e.g. `sharedRepo`, or in older projects `AppAPIRepository.shared`) so the skill instantiates new registry entries consistently:

```swift
// In enum API — uses whatever C1 captured
static var articleRepository: any ArticleRepository {
    ArticleRepositoryImpl(repo: sharedRepo)
}
```

The skill does NOT wire up a new singleton or DI graph; it reuses what exists in `Core/Network/API.swift` (or wherever C1 located the registry file).
